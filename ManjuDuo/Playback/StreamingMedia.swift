// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AVFoundation

/// 边下边播（同官方 App 的机制）：不等整集下完。
/// 先取文件开头的索引（moov，约 150 KB）建立解密表，然后数据到一段、解一段、交给播放器一段；
/// 拖动进度时从新位置重新取数据。临时缓冲在播放结束后清除。
/// 所有状态都只在 `queue` 上读写（资源加载回调和网络回调都派发到这条队列）。
final class StreamSession:NSObject,AVAssetResourceLoaderDelegate,URLSessionDataDelegate,@unchecked Sendable {
    let resource:MediaResource
    let queue=DispatchQueue(label:"manju.stream",qos:.userInitiated)
    /// 自定义协议，让播放器把所有读取都交给本对象。
    var assetURL:URL { URL(string:"manjustream://media/\(resource.episodeID).mp4")! }

    private let file:URL
    private var handle:FileHandle?
    private var session:URLSession?
    private var task:URLSessionDataTask?
    private var taskActive=false
    private var headStart=0,headPosition=0,received=0
    private var total=0
    private var plan:CENCMedia.StreamPlan?
    private var headBuffer=[UInt8]()
    private var covered=[Range<Int>]()
    private var pending=[AVAssetResourceLoadingRequest]()
    private var continuation:CheckedContinuation<Void,Error>?
    private var ready=false,cancelled=false,finished=false
    private var failure:Error?
    private var restarts=0
    private var warming=false
    /// 预热时除了开头，还要提前取「续播位置」附近的数据（0 = 从头看，不需要）。
    private var warmFraction=0.0
    private var warmJumped=false
    private var warmStop=0

    init(resource:MediaResource,file:URL) { self.resource=resource;self.file=file;super.init() }

    /// 开始取数据；索引就绪（可以交给播放器）时返回。文件不是「索引在前」或来源异常时抛错。
    func start(warming:Bool=false,resumeFraction:Double=0) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
                queue.async {
                    guard !self.cancelled else { c.resume(throwing:CancellationError());return }
                    self.warming=warming
                    self.warmFraction=resumeFraction.isFinite ? max(0,min(0.98,resumeFraction)) : 0
                    self.continuation=c
                    let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=30;config.urlCache=nil
                    let operations=OperationQueue();operations.underlyingQueue=self.queue;operations.maxConcurrentOperationCount=1
                    self.session=URLSession(configuration:config,delegate:self,delegateQueue:operations)
                    self.open(at:0)
                }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        queue.async {
            guard !self.cancelled else { return }
            self.cancelled=true
            self.task?.cancel();self.task=nil;self.taskActive=false
            self.session?.invalidateAndCancel();self.session=nil
            for request in self.pending where !request.isFinished && !request.isCancelled { request.finishLoading(with:CancellationError()) }
            self.pending=[]
            self.continuation?.resume(throwing:CancellationError());self.continuation=nil
            try? self.handle?.close();self.handle=nil
            try? FileManager.default.removeItem(at:self.file)
        }
    }

    // MARK: 网络

    private func open(at offset:Int) {
        task?.cancel()
        var request=URLRequest(url:resource.url);request.timeoutInterval=30
        request.setValue("bytes=\(offset)-",forHTTPHeaderField:"Range")
        headStart=offset;headPosition=offset;received=0
        let next=session?.dataTask(with:request);task=next;taskActive=next != nil;next?.resume()
    }

    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) {
        guard let url=request.url,NativePlayback.allowedMedia(url) else {
            completionHandler(nil)
            if task===self.task,!cancelled {
                Trace.mark("media redirect rejected for \(resource.episodeID): HTTP \(response.statusCode), host \(request.url?.host ?? "unknown")")
                fail(ManjuError.message("媒体来源重定向到不受支持的服务器。"))
            }
            return
        }
        Trace.mark("media redirect followed to \(url.host ?? "")")
        var redirected=request
        redirected.setValue(task.originalRequest?.value(forHTTPHeaderField:"Range"),forHTTPHeaderField:"Range")
        completionHandler(redirected)
    }

    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping (URLSession.ResponseDisposition)->Void) {
        guard dataTask===task,!cancelled,failure==nil,let http=response as? HTTPURLResponse else { completionHandler(.cancel);return }
        var size=0
        if http.statusCode==206,let range=http.value(forHTTPHeaderField:"Content-Range"),let slash=range.lastIndex(of:"/") {
            size=Int(range[range.index(after:slash)...]) ?? 0
            let prefix="bytes \(headStart)-"
            guard range.hasPrefix(prefix) else { completionHandler(.cancel);fail(ManjuError.message("媒体来源返回了错误的数据段。"));return }
        } else if http.statusCode==200,headStart==0 {
            size=Int(max(0,http.expectedContentLength))
        }
        guard size>0,size<=200*1024*1024,resource.size==0 || size==resource.size,total==0 || total==size else {
            Trace.mark("stream rejected for \(resource.episodeID): HTTP \(http.statusCode), offset \(headStart), expected size \(resource.size), response size \(size)")
            completionHandler(.cancel);fail(ManjuError.message("媒体流响应无效（HTTP \(http.statusCode)），请重试当前集。"));return
        }
        if total==0 {
            total=size
            do {
                FileManager.default.createFile(atPath:file.path,contents:nil)
                let opened=try FileHandle(forUpdating:file);try opened.truncate(atOffset:UInt64(size));handle=opened
            } catch { completionHandler(.cancel);fail(ManjuError.message("本机缓存无法写入，请检查存储空间。"));return }
            if resource.contentKey==nil { becomeReady() }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
        guard dataTask===task,!cancelled,failure==nil,total>0 else { return }
        received+=data.count
        do {
            try ingest(data)
            // 预热够了就断开，不挂起：挂起太久的连接恢复时会直接报错。开播时已有的数据先播，同时从缺口续取。
            if warming,ready {
                if !warmJumped {
                    let resume=resumeOffset()
                    if headPosition>=(resume==nil ? 1024*1024 : (plan?.header.count ?? 0)+384*1024) {
                        warmJumped=true
                        if let resume,coveredEnd(from:resume)==nil { warmStop=min(total,resume+1536*1024);open(at:resume) }
                        else { task?.cancel();task=nil;taskActive=false }
                    }
                } else if headPosition>=warmStop { task?.cancel();task=nil;taskActive=false }
            }
        } catch { fail(error);return }
        process()
    }

    func urlSession(_ session:URLSession,task finishedTask:URLSessionTask,didCompleteWithError error:Error?) {
        guard finishedTask===task,!cancelled else { return }
        taskActive=false
        if let error {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            // 索引已到手后连接断了：从缺口续取，不让播放器直接报错。
            guard ready,restarts<20 else { fail(ManjuError.message("网络中断，请重试当前集。"));return }
            restarts+=1
            Trace.mark("stream connection dropped (\((error as NSError).code)), continuing from gap")
            queue.asyncAfter(deadline:.now()+0.3) {
                guard !self.cancelled,self.failure==nil,!self.taskActive,!self.warming,!self.finished else { return }
                self.process()
                if !self.taskActive,let gap=self.firstGap() { self.open(at:gap) }
            }
            return
        }
        if covered.count==1,covered[0]==0..<total { complete();return }
        // 连接正常结束但还缺数据：有进展就从缺口续取，没有进展就报错，避免空转。
        if received==0 || restarts>20 { fail(ManjuError.message("媒体下载不完整，请重试当前集。"));return }
        restarts+=1
        process()
        if !warming,!taskActive,failure==nil,let gap=firstGap() { open(at:gap) }
    }

    // MARK: 数据

    private func ingest(_ data:Data) throws {
        if let key=resource.contentKey,plan==nil {
            guard headStart==0 else { throw ManjuError.message("播放准备顺序异常，请重试。") }
            headBuffer.append(contentsOf:data);headPosition+=data.count
            switch CENCMedia.headReady(headBuffer) {
            case .some(true):
                let built=try CENCMedia.plan(head:headBuffer,fileSize:total)
                var rest=Array(headBuffer[built.header.count...])
                try CENCMedia.decrypt(range:&rest,at:built.header.count,samples:built.samples,key:key)
                try write(built.header+rest,at:0)
                plan=built;headBuffer=[]
                becomeReady()
            case .some(false): throw ManjuError.message("此分集的媒体索引不支持流式播放。")
            case .none: if headBuffer.count>8*1024*1024 { throw ManjuError.message("此分集的媒体索引不支持流式播放。") }
            }
            return
        }
        var bytes=[UInt8](data)
        if let key=resource.contentKey,let plan { try CENCMedia.decrypt(range:&bytes,at:headPosition,samples:plan.samples,key:key) }
        try write(bytes,at:headPosition);headPosition+=bytes.count
    }

    private func write(_ bytes:[UInt8],at offset:Int) throws {
        guard let handle,offset>=0,offset+bytes.count<=total else { throw ManjuError.message("媒体数据超出预期长度。") }
        try handle.seek(toOffset:UInt64(offset));try handle.write(contentsOf:bytes)
        insert(offset..<offset+bytes.count)
    }

    private func insert(_ range:Range<Int>) {
        guard !range.isEmpty else { return }
        var merged=range,result=[Range<Int>]()
        for existing in covered {
            if existing.upperBound<merged.lowerBound || existing.lowerBound>merged.upperBound { result.append(existing) }
            else { merged=min(existing.lowerBound,merged.lowerBound)..<max(existing.upperBound,merged.upperBound) }
        }
        result.append(merged);covered=result.sorted{$0.lowerBound<$1.lowerBound}
    }
    private func coveredEnd(from offset:Int) -> Int? { covered.first{$0.contains(offset)}?.upperBound }
    private func firstGap() -> Int? {
        var position=0
        for range in covered { if range.lowerBound>position { return position };position=max(position,range.upperBound) }
        return position<total ? position : nil
    }

    func resumePlayback() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.failure==nil,!self.cancelled else {
                    continuation.resume(returning:false)
                    return
                }
                self.warming=false
                self.process()
                if !self.taskActive,!self.finished {
                    // 接着预热停下的地方往后取；那一段已经到文件末尾就回头补缺口。
                    let next=self.coveredEnd(from:max(0,self.headPosition-1)) ?? self.headPosition
                    if next<self.total { self.open(at:next) } else if let gap=self.firstGap() { self.open(at:gap) }
                }
                continuation.resume(returning:true)
            }
        }
    }

    /// 续播位置大约在文件的哪个字节：有解密表就按采样序号估，没有就按字节比例估。估不准也没关系，播放器要哪段再取哪段。
    private func resumeOffset() -> Int? {
        guard warmFraction>0,total>0 else { return nil }
        if let samples=plan?.samples,!samples.isEmpty { return samples[min(samples.count-1,Int(warmFraction*Double(samples.count)))].offset }
        return Int(warmFraction*Double(total))
    }

    private func becomeReady() { ready=true;continuation?.resume();continuation=nil }

    private func fail(_ error:Error) {
        guard failure==nil,!cancelled else { return }
        failure=error
        task?.cancel();task=nil;taskActive=false
        continuation?.resume(throwing:error);continuation=nil
        for request in pending where !request.isFinished && !request.isCancelled { request.finishLoading(with:error) }
        pending=[]
    }

    private func complete() {
        guard !finished else { return }
        finished=true
        try? handle?.synchronize()
        session?.finishTasksAndInvalidate();session=nil
    }

    // MARK: 播放器的读取请求

    func resourceLoader(_ resourceLoader:AVAssetResourceLoader,shouldWaitForLoadingOfRequestedResource loadingRequest:AVAssetResourceLoadingRequest) -> Bool {
        guard !cancelled,failure==nil,ready else { return false }
        pending.append(loadingRequest);process();return true
    }
    func resourceLoader(_ resourceLoader:AVAssetResourceLoader,didCancel loadingRequest:AVAssetResourceLoadingRequest) {
        pending.removeAll{$0===loadingRequest}
    }

    /// 把已经到手的数据交给各个读取请求；有请求在等一段还没取的数据时，让下载从那里开始。
    private func process() {
        guard ready,failure==nil,!cancelled,let handle else { return }
        var waiting=[AVAssetResourceLoadingRequest]()
        for request in pending where !request.isCancelled && !request.isFinished {
            if let info=request.contentInformationRequest {
                info.contentType=AVFileType.mp4.rawValue;info.contentLength=Int64(total);info.isByteRangeAccessSupported=true
            }
            guard let data=request.dataRequest else { request.finishLoading();continue }
            let end=data.requestsAllDataToEndOfResource ? total : min(total,Int(data.requestedOffset)+data.requestedLength)
            var broken=false
            while Int(data.currentOffset)<end,let available=coveredEnd(from:Int(data.currentOffset)) {
                let position=Int(data.currentOffset),count=min(min(available,end)-position,512*1024)
                guard count>0,(try? handle.seek(toOffset:UInt64(position))) != nil,let chunk=try? handle.read(upToCount:count),!chunk.isEmpty else { broken=true;break }
                data.respond(with:chunk)
            }
            if broken { request.finishLoading(with:ManjuError.message("本机缓存读取失败，请重试当前集。")) }
            else if Int(data.currentOffset)>=end { request.finishLoading() }
            else { waiting.append(request) }
        }
        pending=waiting
        guard !warming,!finished,let first=waiting.first?.dataRequest else { return }
        let need=Int(first.currentOffset)
        // 当前下载马上就会送到这个位置就等它；否则（拖动进度、下载已结束）从需要的位置重新取。
        if !taskActive || need<headStart || need>headPosition+2*1024*1024 { open(at:need) }
    }
}
