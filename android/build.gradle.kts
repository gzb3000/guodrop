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
// Build fix: some pinned plugins (e.g. file_picker 8.x) still compile against android-34,
// but flutter_plugin_android_lifecycle now requires compileSdk >= 36. Raise library compileSdk to 36.
subprojects {
    val forceCompileSdk: Project.() -> Unit = {
        extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)?.let { ext ->
            if ((ext.compileSdkVersion?.removePrefix("android-")?.toIntOrNull() ?: 0) < 36) ext.compileSdk = 36
        }
    }
    if (state.executed) forceCompileSdk() else afterEvaluate { forceCompileSdk() }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
