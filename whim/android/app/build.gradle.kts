import java.io.FileInputStream
import java.util.Properties

// 서명 정보는 저장소에 넣지 않는다(스펙 §10의 키 규칙과 같은 이유). 파일이
// 없으면 릴리스 서명만 못 하고 디버그 빌드는 그대로 된다.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}

plugins {
    id("com.android.application")
    // google-services 플러그인이 google-services.json을 읽어 리소스로 심어주므로
    // FirebaseOptions를 코드에 하드코딩하거나 FlutterFire CLI를 쓸 필요가 없다.
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.whim.app"
    // receive_sharing_intent 1.9.0이 SDK 37에 대해 컴파일되기를 요구한다.
    // flutter.compileSdkVersion은 아직 36이라 직접 올린다. compileSdk는
    // targetSdk/minSdk와 별개라 설치 대상 기기 범위는 그대로다.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.whim.app"
        // Flutter 업그레이드가 minSdk를 조용히 올리면 파일럿 참가자 기기가 떨어져 나가므로 고정한다.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Play 내부 테스트 트랙에 올릴 서명. key.properties가 없는 기기에서는
            // 서명 없이 빌드되어 업로드 단계에서 걸린다 - 조용히 디버그 키로
            // 서명해 올라가는 것보다 낫다.
            signingConfig = signingConfigs.getByName("release")
            // 카카오 지도 SDK 제외 규칙. 축소를 켜는 시점에 빠뜨리면 릴리스에서만
            // 지도가 죽어서 원인을 찾기 어렵다.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
