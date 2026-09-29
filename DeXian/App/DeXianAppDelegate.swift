import UIKit

/// 只负责一件事：让**视频全屏**能转横屏，其余界面一律竖屏。
///
/// Info.plist 里 iPhone 只声明了竖屏，系统不会给任何界面横屏。
/// 影视源大多是 16:9，竖屏全屏后画面只占中间一条，观感很差，
/// 所以这里按「应用级方向锁」放行：默认竖屏，
/// 只有播放器进入全屏时临时允许横屏，退出即收回。
///
/// 不使用「改 Info.plist 放开横屏」的做法：那会让书架、搜索、
/// 正文翻页全部跟着转，反而破坏阅读页的排版假设。
final class DeXianAppDelegate: NSObject, UIApplicationDelegate {

    /// 是否允许横屏。只有视频全屏期间为 true。
    static var allowsLandscape = false

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.allowsLandscape ? [.landscapeLeft, .landscapeRight] : .portrait
    }

    /// 切换允许的方向并立刻驱动界面旋转。
    ///
    /// iOS 16 起 `UIDevice.setValue(_:forKey:"orientation")` 已失效，
    /// 必须走 `UIWindowScene.requestGeometryUpdate`，
    /// 同时通知根控制器重算支持方向，否则系统会拒绝这次旋转。
    static func apply(landscape: Bool) {
        allowsLandscape = landscape
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }

        let mask: UIInterfaceOrientationMask = landscape
            ? [.landscapeLeft, .landscapeRight]
            : .portrait

        // 不用 scene.keyWindow：它是 iOS 15+ 才对 UIWindowScene 暴露的属性，
        // 而这里要兼容 iOS 16 部署目标下的全部形态，直接从 windows 里挑更稳。
        let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        root?.setNeedsUpdateOfSupportedInterfaceOrientations()

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
}
