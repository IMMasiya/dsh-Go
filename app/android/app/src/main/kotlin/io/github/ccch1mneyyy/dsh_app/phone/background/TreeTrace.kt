package io.github.ccch1mneyyy.dsh_app.phone.background

/** TEMPORARY field diagnostic for the background-screen tree registration; delete after use. */
internal object TreeTrace {
    private const val path = "/sdcard/Download/DSH-Go/tree-trace.txt"
    private val stamp = java.text.SimpleDateFormat("HH:mm:ss.SSS", java.util.Locale.US)

    fun log(message: String) {
        runCatching {
            val file = java.io.File(path)
            file.parentFile?.mkdirs()
            java.io.FileWriter(file, true).use {
                it.write("${stamp.format(java.util.Date())} ${Thread.currentThread().name} $message\n")
            }
        }
    }
}
