allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// cunning_document_scanner pins compileSdk 33 while its androidx deps demand
// 34+ (checkReleaseAarMetadata fails the build). Force stale plugin
// compileSdks up to the app's level; remove when the plugin catches up.
subprojects {
    // :app is already evaluated via evaluationDependsOn above (and sets its
    // own compileSdk from flutter anyway) — afterEvaluate would throw on it.
    if (!state.executed) afterEvaluate {
        extensions.findByType(com.android.build.gradle.BaseExtension::class.java)?.let { ext ->
            val current = ext.compileSdkVersion?.removePrefix("android-")?.toIntOrNull()
            if (current != null && current < 35) {
                ext.compileSdkVersion(35)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
