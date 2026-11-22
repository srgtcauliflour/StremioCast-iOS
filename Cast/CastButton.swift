import SwiftUI
import GoogleCast
struct CastButton: UIViewRepresentable {
 let url:URL; let title:String
 func makeCoordinator()->Coordinator{Coordinator(url:url,title:title)}
 func makeUIView(context:Context)->GCKUICastButton{
  let b=GCKUICastButton(frame:CGRect(x:0,y:0,width:38,height:38));b.tintColor = .white
  b.addTarget(context.coordinator,action:#selector(Coordinator.queueMedia),for:.touchUpInside);b.accessibilityLabel="Cast to Chromecast";return b
 }
 func updateUIView(_ v:GCKUICastButton,context:Context){context.coordinator.url=url;context.coordinator.title=title}
 final class Coordinator:NSObject{var url:URL;var title:String;init(url:URL,title:String){self.url=url;self.title=title};@objc func queueMedia(){CastManager.shared.queue(url,title:title)}}
}
