// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
struct ConfiguredRun:Codable,Equatable {
    var version=1
    var id=UUID()
    var name:String
    var executable:String
    var arguments:[String]
    var shellMode=false
    var extensionMode=false
    func validate()throws {
        guard version==1,!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count<=200,
              executable.hasPrefix("/"),!executable.contains("\0"),arguments.count<=256,
              arguments.allSatisfy({!$0.contains("\0") && $0.utf8.count<=1024*1024}),
              !(shellMode && extensionMode) else {throw RunFailure.invalid}
        if shellMode && (executable != "/bin/zsh" || arguments.count != 2 || arguments.first != "-c") {throw RunFailure.invalid}
    }
    func resolved(file:URL?,selection:String)throws->Self {
        try validate();var result=self
        // Shell code never interpolates document contents. Those values are exposed
        // only through positional argv in ordinary executable mode.
        if !shellMode {
            result.arguments=try arguments.map { arg in
                if arg == "{file}" {guard let file else {throw RunFailure.fileRequired};return file.path}
                if arg == "{directory}" {guard let file else {throw RunFailure.fileRequired};return file.deletingLastPathComponent().path}
                if arg == "{selection}" {return selection}
                return arg
            }
        }
        try result.validate();return result
    }
    static func validateLibrary(_ commands:[Self])throws {
        guard commands.count<=1000,Set(commands.map(\.id)).count==commands.count else{throw RunFailure.invalid}
        for command in commands{try command.validate()}
    }
    /// One shared byte ceiling for persistence and restart, including JSON escaping.
    static let maximumLibraryBytes=1024*1024
    static func encodeLibrary(_ commands:[Self])throws->Data {
        try validateLibrary(commands)
        // Reject obviously oversized inputs before JSONEncoder allocates an expanded
        // representation. JSON overhead/escaping is checked on the encoded result.
        var remaining=maximumLibraryBytes
        for command in commands {
            for field in [command.name,command.executable]+command.arguments {
                let bytes=field.utf8.count
                guard bytes<=remaining else{throw RunFailure.configurationTooLarge}
                remaining-=bytes
            }
        }
        let data=try JSONEncoder().encode(commands)
        guard data.count<=maximumLibraryBytes else{throw RunFailure.configurationTooLarge}
        return data
    }
    static func decodeLibrary(_ data:Data)throws->[Self] {
        guard data.count<=maximumLibraryBytes else{throw RunFailure.configurationTooLarge}
        let commands=try JSONDecoder().decode([Self].self,from:data)
        try validateLibrary(commands)
        return commands
    }
    /// Version 1 extension contract: UTF-8 document/selection on stdin, UTF-8 result
    /// on stdout, diagnostics on stderr, exit 0 required. No automatic mutation.
    static var uppercaseSample:Self {Self(name:"Uppercase ASCII (sample extension)",executable:"/usr/bin/tr",arguments:["a-z","A-Z"],extensionMode:true)}
}
enum RunFailure:Error,LocalizedError {
    case invalid,fileRequired,busy,tooLarge,configurationTooLarge
    var errorDescription:String? {
        switch self {
        case .invalid:return "Invalid command configuration. Use an absolute executable path and an argument array."
        case .fileRequired:return "This command needs a saved document path."
        case .busy:return "A command is already running."
        case .configurationTooLarge:return "Saved Run commands exceed the 1 MiB configuration limit. Shorten arguments or remove commands; the existing configuration was preserved."
        case .tooLarge:return "Process input or output exceeds the 4 MiB limit."
        }
    }
}
struct RunResult {let stdout:Data,stderr:Data,status:Int32;let cancelled:Bool,truncated:Bool}
/// Explicit process group with bounded nonblocking pipes. Imports are inert.
final class RunExecution:@unchecked Sendable {
    private let lock=NSLock()
    private var active=false,cancelRequested=false
    func cancel(){lock.lock();cancelRequested=true;lock.unlock()}
    private var cancelled:Bool {lock.lock();defer{lock.unlock()};return cancelRequested}
    func execute(_ command:ConfiguredRun,input:Data=Data(),timeout:TimeInterval=30)throws->RunResult {
        try command.validate();guard input.count<=4*1024*1024 else{throw RunFailure.tooLarge}
        lock.lock();guard !active else{lock.unlock();throw RunFailure.busy};active=true;lock.unlock()
        defer{lock.lock();active=false;lock.unlock()}
        if cancelled{return RunResult(stdout:Data(),stderr:Data(),status:-1,cancelled:true,truncated:false)}
        func failure()->POSIXError {POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        // Anonymous temporary input avoids SIGPIPE and a blocked writer when a child
        // deliberately never reads stdin. tmpfile is private and unlinked by libc.
        guard let file=tmpfile() else{throw failure()};defer{fclose(file)}
        if !input.isEmpty {
            let written=input.withUnsafeBytes{fwrite($0.baseAddress,1,input.count,file)}
            guard written==input.count,fflush(file)==0 else{throw failure()}
        }
        rewind(file)
        var stdoutPipe:[Int32]=[0,0],stderrPipe:[Int32]=[0,0]
        guard pipe(&stdoutPipe)==0 else{throw failure()}
        guard pipe(&stderrPipe)==0 else{close(stdoutPipe[0]);close(stdoutPipe[1]);throw failure()}
        var descriptors=stdoutPipe+stderrPipe
        defer{for fd in descriptors where fd>=0{close(fd)}}
        for fd in [stdoutPipe[0],stderrPipe[0]]{guard fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK)==0 else{throw failure()}}
        var actions:posix_spawn_file_actions_t?,attributes:posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions)==0,posix_spawnattr_init(&attributes)==0 else{throw RunFailure.invalid}
        defer{posix_spawn_file_actions_destroy(&actions);posix_spawnattr_destroy(&attributes)}
        posix_spawn_file_actions_adddup2(&actions,fileno(file),STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions,stdoutPipe[1],STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions,stderrPipe[1],STDERR_FILENO)
        for fd in descriptors{posix_spawn_file_actions_addclose(&actions,fd)}
        posix_spawn_file_actions_addclose(&actions,fileno(file))
        posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_SETPGROUP|POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes,0)
        var argv=([command.executable]+command.arguments).map{strdup($0)}+[nil]
        var env=ProcessInfo.processInfo.environment.map{strdup($0.key+"="+$0.value)}+[nil]
        defer{for p in argv{free(p)};for p in env{free(p)}}
        var pid:pid_t=0
        let launched=posix_spawn(&pid,command.executable,&actions,&attributes,&argv,&env)
        guard launched==0 else{throw POSIXError(POSIXErrorCode(rawValue:launched) ?? .EIO)}
        close(stdoutPipe[1]);descriptors[1] = -1;close(stderrPipe[1]);descriptors[3] = -1
        var output=Data(),errors=Data(),eof=[false,false],status:Int32=0,exited=false,limited=false,stopped=false
        let deadline=Date().addingTimeInterval(max(0.05,min(timeout,300)))
        var exitDate:Date?
        func drain(_ fd:Int32,_ destination:inout Data,_ ended:inout Bool){
            var bytes=[UInt8](repeating:0,count:65536)
            for _ in 0..<64 {
                let n=read(fd,&bytes,bytes.count)
                if n==0{ended=true;break}
                if n<0{if errno != EAGAIN && errno != EINTR{ended=true};break}
                let remaining=max(0,4*1024*1024-output.count-errors.count-destination.count)
                destination.append(contentsOf:bytes.prefix(min(n,remaining)))
                if n>remaining{limited=true;break}
            }
        }
        while true {
            // Separate temporary buffers avoid overlapping inout access to output.
            var chunk=Data();drain(stdoutPipe[0],&chunk,&eof[0]);output.append(chunk)
            chunk=Data();drain(stderrPipe[0],&chunk,&eof[1]);errors.append(chunk)
            if !exited {
                let waited=waitpid(pid,&status,WNOHANG)
                if waited==pid{exited=true;exitDate=Date()}
                else if waited<0 && errno != EINTR{exited=true;exitDate=Date()}
            }
            if exited && eof.allSatisfy({$0}){break}
            if cancelled || Date()>=deadline || limited {stopped=true;kill(-pid,SIGTERM);break}
            if let exitDate,Date().timeIntervalSince(exitDate)>0.5 {
                // A descendant holding output open belongs to this configured run.
                limited=true;kill(-pid,SIGTERM);break
            }
            Thread.sleep(forTimeInterval:0.005)
        }
        if stopped || limited {
            let grace=Date().addingTimeInterval(0.1)
            while !exited && Date()<grace {
                if waitpid(pid,&status,WNOHANG)==pid{exited=true;break}
                Thread.sleep(forTimeInterval:0.005)
            }
            kill(-pid,SIGKILL)
        }
        if !exited{while waitpid(pid,&status,0)<0 && errno==EINTR{}}
        // Runs are scoped jobs, never implicit daemon launchers. Clean up remaining
        // group members even if the leader exited and descendants closed output.
        if kill(-pid,0)==0 {kill(-pid,SIGTERM);Thread.sleep(forTimeInterval:0.1);kill(-pid,SIGKILL)}
        let exitStatus=(status & 0x7f)==0 ? (status>>8)&0xff : 128+(status&0x7f)
        return RunResult(stdout:output,stderr:errors,status:exitStatus,cancelled:stopped,truncated:limited)
    }
}
