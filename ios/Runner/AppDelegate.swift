import Flutter
import UIKit
import UserNotifications
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Google Maps SDK MUSS vor dem ersten GMSMapView-Mount initialisiert
    // werden — sonst fataler NSException-Crash beim Mounten des Map-Tabs
    // (HomeShell baut den Map-Screen über IndexedStack direkt nach Login).
    // iOS-restricted Key aus Google Cloud Console (separat vom Android-
    // Key in AndroidManifest.xml — beide laufen über Bundle-ID-Restriction).
    GMSServices.provideAPIKey("AIzaSyBGcuGxbH6Gm0lGAGNmB97NSaw8D3DXRpc")

    GeneratedPluginRegistrant.register(with: self)
    // Required so iOS shows notification banners when the app is in the foreground
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
