import Cocoa
import AVFoundation

enum VocabPreferences {
    static var provider:String {UserDefaults.standard.string(forKey:"VocabAIProvider") ?? "qoder-cn"}
    static var model:String {UserDefaults.standard.string(forKey:"VocabAIModel") ?? "DeepSeek-Flash"}
    static var effort:String {UserDefaults.standard.string(forKey:"VocabAIEffort") ?? "high"}
    static var voiceEndpoint:String {UserDefaults.standard.string(forKey:"VocabVoiceEndpoint") ?? "http://127.0.0.1:8977/inference"}
    static func validVoice(_ value:String)->URL? {
        guard let url=URL(string:value),["http","https"].contains(url.scheme ?? ""),
              ["localhost","127.0.0.1","::1","[::1]"].contains(url.host ?? ""),url.user==nil,url.password==nil else{return nil}
        return url
    }
    static func validIdentifier(_ value:String)->Bool {
        !value.isEmpty && value.count<=160 && !value.hasPrefix("-") && value.range(of:"^[A-Za-z0-9][A-Za-z0-9._:/+ -]*$",options:.regularExpression) != nil
    }
}

struct AssistantEvent: Codable {
    var type: String
    var request: String?
    var turn: String?
    var text: String?
    var queue: String?
    var model: String? = nil
    var effort: String? = nil
    var provider: String? = nil
    var sourceLabel: String? {
        guard let model else { return nil }
        return provider.map { "\(model) · \($0 == "qoder-cn" ? "Qoder CN":$0)"+(effort.map{" · \($0.uppercased())"} ?? "") } ?? model
    }
}

class LanguageAssistant {
    private var processes: [String: Process] = [:]
    private var cancelled: Set<String> = []
    private var closing=false
    private let lock = NSLock()
    var thread: String {
        let saved = UserDefaults.standard.string(forKey:"VocabAssistantThread") ?? ""
        return UUID(uuidString:saved) == nil ? "" : saved
    }
    func open() {
        guard !thread.isEmpty else{return}
        if let url = URL(string:"codex://threads/\(thread)") {
            NSWorkspace.shared.open(url)
        }
    }
    func cancel(_ id: String) {
        lock.lock(); let p = processes[id]; processes.removeValue(forKey:id); cancelled.insert(id); lock.unlock()
        // Direct requests stop their local worker. An already queued Codex handoff remains in Codex.
        if p?.isRunning == true { p?.terminate() }
    }
    func cancelAll(){
        lock.lock();closing=true;let ids=Array(processes.keys);lock.unlock()
        for id in ids{cancel(id)}
    }
    func ask(_ prompt: String, request: String = UUID().uuidString, route: String = "pi",
             callback: @escaping (AssistantEvent) -> Void) {
        let currentThread = thread
        if route != "pi" && currentThread.isEmpty {
            callback(.init(type:"error",request:request,text:"请先在设置中绑定自己的 Codex 会话。"));return
        }
        let provider=VocabPreferences.provider,model=VocabPreferences.model,effort=VocabPreferences.effort
        lock.lock();guard !closing else{lock.unlock();return};cancelled.remove(request); lock.unlock()
        DispatchQueue.global(qos:.userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
            p.arguments = [Paths.resource("bridge").path]
            let stdin = Pipe(), stdout = Pipe()
            p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
            let config: [String:Any] = ["thread":currentThread, "request":request,
                                       "prompt":prompt, "route":route, "timeout":120,
                                       "provider":provider,"model":model,"effort":effort]
            func send(_ e: AssistantEvent) { DispatchQueue.main.async { callback(e) } }
            do {
                let payload = try JSONSerialization.data(withJSONObject:config)
                self.lock.lock()
                if self.closing || self.cancelled.contains(request) { self.lock.unlock(); return }
                do { try p.run() } catch { self.lock.unlock(); throw error }
                self.processes[request] = p; self.lock.unlock()
                stdin.fileHandleForWriting.write(payload)
                try stdin.fileHandleForWriting.close()
                var buffer = Data()
                var terminal = false
                while true {
                    let bytes = stdout.fileHandleForReading.availableData
                    if bytes.isEmpty { break }
                    buffer.append(bytes)
                    while let i = buffer.firstIndex(of:10) {
                        let line = buffer.prefix(upTo:i)
                        buffer.removeSubrange(...i)
                        if let e = try? JSONDecoder().decode(AssistantEvent.self,from:Data(line)) {
                            if ["result","error","timeout"].contains(e.type) { terminal = true }
                            send(e)
                        }
                    }
                }
                p.waitUntilExit()
                self.lock.lock()
                let wasCancelled = self.processes.removeValue(forKey:request) == nil
                self.lock.unlock()
                if !terminal && !wasCancelled {
                    send(AssistantEvent(type:"error",request:request,text:"未能读取语言助手回复；可以打开完整对话。"))
                }
            } catch {
                self.lock.lock(); self.processes.removeValue(forKey:request); self.lock.unlock()
                send(AssistantEvent(type:"error",request:request,text:error.localizedDescription))
            }
        }
    }
}

final class VoiceInput: NSObject, ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var busy = false
    @Published var message = ""
    @Published private(set) var owner:String?
    private var completion:((String)->Void)?
    private var recordingEnglish=false
    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var began = Date()
    private var generation = UUID()
    private var task: URLSessionDataTask?

    func toggle(english: Bool,owner:String="lookup", onText: @escaping (String) -> Void) {
        guard self.owner==nil || self.owner==owner else{message="另一处输入正在录音或转写，请先完成。";return}
        if recording {stop(english:recordingEnglish,onText:completion ?? onText);return}
        guard !busy else { return }
        switch AVCaptureDevice.authorizationStatus(for:.audio) {
        case .authorized:
            start(english:english,owner:owner,onText:onText)
        case .notDetermined:
            self.owner=owner;busy=true;message="等待麦克风权限…"
            let request=UUID();generation=request
            AVCaptureDevice.requestAccess(for:.audio) { yes in
                DispatchQueue.main.async {
                    guard self.generation==request,self.owner==owner else{return}
                    self.busy=false
                    if yes{self.start(english:english,owner:owner,onText:onText)}
                    else{self.owner=nil;self.message="麦克风未授权，可继续输入文字。"}
                }
            }
        default: message = "麦克风未授权，可在系统设置中开启。"
        }
    }
    private func start(english: Bool,owner:String, onText: @escaping (String) -> Void) {
        guard !recording, !busy else { return }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-voice-\(UUID().uuidString).wav")
        let settings:[String:Any] = [AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:16000,
                                     AVNumberOfChannelsKey:1, AVLinearPCMBitDepthKey:16,
                                     AVLinearPCMIsFloatKey:false, AVLinearPCMIsBigEndianKey:false]
        do {
            let r = try AVAudioRecorder(url:path,settings:settings)
            guard r.record() else { throw SupportError.message("无法录音") }
            self.owner=owner;completion=onText;recordingEnglish=english
            recorder = r; url = path; began = Date(); recording = true; message = "录音中 · 再点击结束"
            let id = UUID(); generation = id
            DispatchQueue.main.asyncAfter(deadline:.now()+120) { [weak self] in
                guard let self, self.recording, self.generation == id else { return }
                self.stop(english:english,onText:onText)
            }
        } catch {message=error.localizedDescription;self.owner=nil;completion=nil}
    }
    private func stop(english: Bool, onText: @escaping (String) -> Void) {
        recorder?.stop(); recorder = nil; recording = false
        guard let url else {owner=nil;completion=nil;return}
        self.url = nil
        let seconds = Date().timeIntervalSince(began)
        guard seconds >= 0.35, let wav = try? Data(contentsOf:url) else {
            try? FileManager.default.removeItem(at:url);message = "录音太短";owner=nil;completion=nil;return
        }
        try? FileManager.default.removeItem(at:url)
        let boundary = "vocab-" + UUID().uuidString
        var data = Data()
        func part(_ name:String,_ value:String) {
            data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        part("language", english ? "en" : "auto")
        part("response_format","json"); part("temperature","0.0"); part("translate","false")
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"vocab.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        data.append(wav); data.append(Data("\r\n--\(boundary)--\r\n".utf8))
        guard let endpoint=VocabPreferences.validVoice(VocabPreferences.voiceEndpoint) else{message="请在设置中填写有效的本机语音地址。";owner=nil;completion=nil;return}
        var req = URLRequest(url:endpoint)
        req.httpMethod = "POST"; req.timeoutInterval = 45; req.httpBody = data
        req.setValue("multipart/form-data; boundary=\(boundary)",forHTTPHeaderField:"Content-Type")
        busy = true; message = "本机识别中…"
        let id = UUID(); generation = id
        task = URLSession.shared.dataTask(with:req) { [weak self] bytes,response,error in
            let text = bytes.flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }?["text"] as? String
            DispatchQueue.main.async {
                guard let self,self.generation==id else { return }
                self.busy=false; self.task=nil
                if let text, !cleanText(text).isEmpty, (response as? HTTPURLResponse)?.statusCode == 200 {
                    self.message="已识别，可编辑后发送"; onText(cleanText(text))
                } else { self.message="本机识别未成功；请重试或输入文字（检查 OMLXVoice 服务）。" }
                self.owner=nil;self.completion=nil
            }
        }
        task?.resume()
    }
    func cancel(owner expected:String?=nil) {
        if let expected,owner != expected{return}
        generation = UUID()
        recorder?.stop(); recorder=nil
        if let url { try? FileManager.default.removeItem(at:url) }
        url=nil; task?.cancel(); task=nil; recording=false; busy=false; message="";owner=nil;completion=nil
    }
}
