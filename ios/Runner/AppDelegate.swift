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
    // Gegenstück zu com.google.android.geo.API_KEY im AndroidManifest.
    GMSServices.provideAPIKey("AIzaSyD87LYkHyCjLJbh5dH3Mc6yeiXF9zH_ly8")

    GeneratedPluginRegistrant.register(with: self)
    // Required so iOS shows notification banners when the app is in the foreground
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
