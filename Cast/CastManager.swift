import Foundation
import GoogleCast

@MainActor final class CastManager: NSObject, ObservableObject, GCKSessionManagerListener {
 static let shared = CastManager()
 @Published private(set) var connected = false
 private var pending: (URL,String)?
 private var initialized = false
 func setup() {
  guard !initialized else{return}; initialized=true
  let opts=GCKCastOptions(discoveryCriteria:GCKDiscoveryCriteria(applicationID:kGCKDefaultMediaReceiverApplicationID))
  GCKCastContext.setSharedInstanceWith(opts)
  GCKCastContext.sharedInstance().sessionManager.add(self)
  GCKCastContext.sharedInstance().useDefaultExpandedMediaControls=true
 }
 func queue(_ url:URL,title:String){pending=(url,title)}
 private func send(_ s:GCKCastSession){
  guard let p=pending else{return}
  let ext=p.0.pathExtension.lowercased()
  let type=["m3u8":"application/x-mpegURL","mpd":"application/dash+xml","mp4":"video/mp4","mkv":"video/x-matroska","webm":"video/webm","mov":"video/quicktime"][ext] ?? "application/octet-stream"
  let md=GCKMediaMetadata(metadataType:.movie); md.setString(p.1,forKey:kGCKMetadataKeyTitle)
  let b=GCKMediaInformationBuilder(contentURL:p.0); b.contentType=type; b.streamType = .buffered; b.metadata=md
  s.remoteMediaClient?.loadMedia(b.build())
  GCKCastContext.sharedInstance().presentDefaultExpandedMediaControls()
  pending=nil
 }
 func sessionManager(_ m:GCKSessionManager,didStart s:GCKSession,withError e:Error?){connected=e==nil;if let s=s as? GCKCastSession{send(s)}}
 func sessionManager(_ m:GCKSessionManager,didResume s:GCKSession,withError e:Error?){connected=e==nil;if let s=s as? GCKCastSession{send(s)}}
 func sessionManager(_ m:GCKSessionManager,didEnd s:GCKSession,withError e:Error?){connected=false;pending=nil}
 func sessionManager(_ m:GCKSessionManager,didFailToStart s:GCKSession,withError e:Error?){connected=false}
 func sessionManager(_ m:GCKSessionManager,didSuspend s:GCKSession,withReason r:GCKConnectionSuspendReason){connected=false}
 func sessionManager(_ m:GCKSessionManager,didUpdate s:GCKSession){connected=m.currentCastSession != nil}
}
