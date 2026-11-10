plugins {
    id("com.android.application")
}

// CI and scripts/build-apk.sh set these explicitly. Direct Gradle/Android
// Studio builds fall back to the tag in UPSTREAM_VERSION so the APK never
// silently reports a hard-coded 1.0. The tag keeps its leading "v"; Android's
// numeric fields use the version without it.
val upstreamVersion = rootProject.file("../UPSTREAM_VERSION")
    .takeIf { it.isFile }
    ?.readLines()
    ?.firstOrNull { it.startsWith("tag=") }
    ?.substringAfter("tag=")
    ?.trim()
    ?.removePrefix("v")
    ?.takeIf { it.isNotEmpty() }
val magpieVersionName = System.getenv("MAGPIE_VERSION_NAME")
    ?.takeIf { it.isNotBlank() }
    ?: upstreamVersion
    ?: "1.0"
val fallbackVersionCode = Regex("""^(\d+)\.(\d+)\.(\d+)""")
    .find(magpieVersionName)
    ?.groupValues
    ?.drop(1)
    ?.map { it.toInt() }
    ?.let { (major, minor, patch) -> major * 10_000_000 + minor * 1_000_000 + patch }
    ?: 1
val magpieVersionCode = System.getenv("MAGPIE_VERSION_CODE")
    ?.toIntOrNull()
    ?: fallbackVersionCode

// Signing is driven from the environment so that every CI run signs with the
// same key. MAGPIE_KEYSTORE points at a PKCS12 or JKS keystore (absolute path,
// or relative to the repository root). When it is absent — local builds, pull
// requests from forks without secrets — Gradle falls back to its automatic
// debug key, which is fine for a quick install but yields a *different*
// certificate on every machine, so those APKs cannot update one another.
val magpieKeystorePath = System.getenv("MAGPIE_KEYSTORE")?.trim()?.takeIf { it.isNotEmpty() }
val magpieKeystoreFile = magpieKeystorePath?.let { path ->
    val file = java.io.File(path)
    if (file.isAbsolute) file else rootProject.file(path)
}
val magpieKeystorePassword = System.getenv("MAGPIE_KEYSTORE_PASSWORD")
val magpieKeyAlias = System.getenv("MAGPIE_KEY_ALIAS")?.trim()?.takeIf { it.isNotEmpty() } ?: "magpie"
val magpieKeyPassword = System.getenv("MAGPIE_KEY_PASSWORD")?.takeIf { it.isNotEmpty() }
    ?: magpieKeystorePassword
if (magpieKeystoreFile != null) {
    require(magpieKeystoreFile.isFile) {
        "MAGPIE_KEYSTORE points at a missing file: ${magpieKeystoreFile.absolutePath}"
    }
}

android {
    namespace = "com.magpie.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.magpie.android"
        // Android 13 (API 33). The gateway is linked against API 33 as well
        // (see scripts/build-magpie-android.ps1), so nothing in the APK asks
        // for a symbol an Android 13 device doesn't have.
        minSdk = 33
        targetSdk = 36
        versionCode = magpieVersionCode
        versionName = magpieVersionName
        // The Go gateway is built by scripts/build-magpie-android.ps1 into
        // src/main/jniLibs/<abi>/libmagpie.so; Gradle only packages it, the
        // NDK is used by that script and not by this build.
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    signingConfigs {
        // Only created when a keystore is supplied; otherwise the built-in
        // "debug" config stays the sole one and behaves exactly as before.
        // storeType is deliberately left unset so both PKCS12 and JKS work
        // (the Android Gradle plugin detects the format from the file).
        if (magpieKeystoreFile != null) {
            create("magpie") {
                storeFile = magpieKeystoreFile
                storePassword = magpieKeystorePassword
                keyAlias = magpieKeyAlias
                keyPassword = magpieKeyPassword
            }
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            if (magpieKeystoreFile != null) {
                signingConfig = signingConfigs.getByName("magpie")
            }
        }
        release {
            isMinifyEnabled = false
            // One stable key for every build, so an APK can install over the
            // previous one. Without the environment keystore we can only fall
            // back to the debug key, as this project used to do.
            signingConfig = signingConfigs.getByName(
                if (magpieKeystoreFile != null) "magpie" else "debug"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        jniLibs {
            // The gateway is exec'd from the app's native library directory,
            // so the libraries must be extracted onto disk.
            useLegacyPackaging = true
            // Bun is carried the same way (jniLibs/<abi>/libmagpiebun.so) and
            // is exec'd from there too: AGP must not strip it.
            keepDebugSymbols += "**/libmagpiebun.so"
        }
    }

    androidResources {
        // No need to compress the big binary further; keeps extraction quick.
        noCompress += "so"
    }
}
