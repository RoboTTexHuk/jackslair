import UIKit
import Flutter
import Firebase
import FirebaseMessaging

@main
@objc class AppDelegate: FlutterAppDelegate, MessagingDelegate {
  
  let methodChannelName = "com.example.app"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    
      // Инициализация Firebase
      FirebaseApp.configure()
      Messaging.messaging().delegate = self
      

    
    // Запрос разрешения на уведомления
    UNUserNotificationCenter.current().delegate = self
    let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
    UNUserNotificationCenter.current().requestAuthorization(options: authOptions) { [weak self] granted, error in
      if let error = error {
        print("Ошибка при запросе разрешений на уведомления: \(error.localizedDescription)")
      } else {
        print("Разрешение на уведомления предоставлено: \(granted)")
        
        if granted {
          DispatchQueue.main.async {
            application.registerForRemoteNotifications()
          }
          
          // Попытка получить FCM-токен сразу
          Messaging.messaging().token { token, error in
            if let error = error {
              print("Ошибка получения FCM токена: \(error.localizedDescription)")
            } else if let token = token {
              print("FCM токен получен: \(token)")
              self?.sendTokenToFlutter(token: token)
            }
          }
        }
      }
    }
    
    // Настройка MethodChannel
    if let controller = window?.rootViewController as? FlutterViewController {
      let methodChannel = FlutterMethodChannel(name: methodChannelName, binaryMessenger: controller.binaryMessenger)
      
      // Обработчик вызовов MethodChannel (если требуется для других целей)
      methodChannel.setMethodCallHandler { (call: FlutterMethodCall, result: FlutterResult) in
        // Обработка вызовов от Flutter
      }
    }
    
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Отправка FCM токена в Flutter
  private func sendTokenToFlutter(token: String) {
    if let controller = window?.rootViewController as? FlutterViewController {
      let fcmChannel = FlutterMethodChannel(name: "com.example.fcm/token", binaryMessenger: controller.binaryMessenger)
      fcmChannel.invokeMethod("setToken", arguments: token)
    }
  }

  // Обработка обновления FCM токена
  func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
    print("FCM токен обновлен: \(String(describing: fcmToken))")
    if let token = fcmToken {
      sendTokenToFlutter(token: token)
    }
  }

  // Обработка APNs токена
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Messaging.messaging().apnsToken = deviceToken
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }
  
  // Обработка foreground уведомлений
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let userInfo = notification.request.content.userInfo
    print("Уведомление получено в foreground: \(userInfo)")
    
    if let controller = window?.rootViewController as? FlutterViewController {
      let notificationChannel = FlutterMethodChannel(name: "com.example.fcm/notification", binaryMessenger: controller.binaryMessenger)
      notificationChannel.invokeMethod("onMessage", arguments: userInfo)
    }
    
    completionHandler([[.alert, .sound, .badge]])
  }
  
  // Обработка нажатия на уведомление
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    print("Пользователь взаимодействовал с уведомлением: \(userInfo)")

    // Извлечение title, body и URI
    let aps = userInfo["aps"] as? [String: Any]
    let alert = aps?["alert"] as? [String: Any]
    let title = alert?["title"] as? String ?? "Без заголовка"
    let body = alert?["body"] as? String ?? "Без текста"
    let uri = userInfo["uri"] as? String ?? "Нет URI"

    // Создание структуры данных для передачи во Flutter
    let notificationData: [String: Any] = [
      "title": title,
      "body": body,
      "uri": uri,
      "data": userInfo
    ]

    // Передача данных во Flutter через MethodChannel
    if let controller = window?.rootViewController as? FlutterViewController {
      let notificationChannel = FlutterMethodChannel(name: "com.example.fcm/notification", binaryMessenger: controller.binaryMessenger)
      notificationChannel.invokeMethod("onNotificationTap", arguments: notificationData)
    }

    completionHandler()
  }
  
  // Обработка уведомлений в background
  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    print("Уведомление получено в background: \(userInfo)")

    // Извлечение необходимых данных: title, body и uri
    let title = (userInfo["title"] as? String) ?? "No title"
    let body = (userInfo["body"] as? String) ?? "No body"
    let uri = (userInfo["uri"] as? String) ?? "No URI"

    // Формируем данные для передачи в Flutter
    let notificationData: [String: Any] = [
      "title": title,
      "body": body,
      "uri": uri
    ]

    // Проверяем наличие FlutterViewController
    if let controller = window?.rootViewController as? FlutterViewController {
      let methodChannel = FlutterMethodChannel(
        name: methodChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      
      // Передаем данные в Flutter через MethodChannel
      methodChannel.invokeMethod("handleMessageBackground", arguments: notificationData) { _ in
        completionHandler(.newData)
      }
    } else {
      completionHandler(.noData)
    }
  }
}
