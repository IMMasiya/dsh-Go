package io.github.ccch1mneyyy.dsh_app.documents

import android.content.ContentResolver
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import android.webkit.MimeTypeMap
import io.github.ccch1mneyyy.dsh_app.R
import java.io.File
import java.io.FileNotFoundException

/**
 * 把 DSH 家目录（Linux 环境里的 /root，即 `filesDir/runtime/rootfs/root`）暴露给系统文件
 * 管理器：DocumentsProvider 让「添加存储 → 内部存储」里能浏览它。
 *
 * 家目录里是会话、配置与工作区（DSH_HOME），是用户真正关心的数据；rootfs 其余部分
 * （Linux 系统文件）不暴露，避免误删，也避免枚举几十万文件。
 *
 * documentId 约定：根为 [ROOT_ID]；其余为相对家目录的路径，如 "workspace/project/a.md"。
 * 所有路径在 [fileFor] 里做规范化和根约束，阻止 `..` 或符号链接逃出家目录。
 */
class AppDocumentsProvider : DocumentsProvider() {

    companion object {
        private const val ROOT_ID = "root"
        private const val AUTHORITY_SUFFIX = ".documents"

        /** 目录：可新建、重命名、删除。 */
        private const val DIR_FLAGS =
            DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE or
                DocumentsContract.Document.FLAG_SUPPORTS_DELETE or
                DocumentsContract.Document.FLAG_SUPPORTS_RENAME

        /** 文件：可写、重命名、删除。 */
        private const val FILE_FLAGS =
            DocumentsContract.Document.FLAG_SUPPORTS_WRITE or
                DocumentsContract.Document.FLAG_SUPPORTS_DELETE or
                DocumentsContract.Document.FLAG_SUPPORTS_RENAME

        /** 根：支持新建，并支持树选择（ACTION_OPEN_DOCUMENT_TREE 需要 IS_CHILD）。 */
        private const val ROOT_FLAGS =
            DocumentsContract.Root.FLAG_SUPPORTS_IS_CHILD or
                DocumentsContract.Root.FLAG_SUPPORTS_CREATE
    }

    private var appContext: Context? = null
    private var rootDir: File? = null

    override fun onCreate(): Boolean {
        appContext = context?.applicationContext
        rootDir = appContext?.let { File(it.filesDir, "runtime/rootfs/root") }
        return true
    }

    // ==== 文档定位与校验 ====

    private fun root(): File = rootDir ?: throw FileNotFoundException("Provider not ready")

    private fun authority(): String = requireNotNull(appContext).packageName + AUTHORITY_SUFFIX

    /** documentId → 物理文件；根返回家目录，其余必须是家目录内的相对路径（规范化防逃逸）。 */
    private fun fileFor(documentId: String): File? {
        if (documentId == ROOT_ID) return root()
        if (documentId.isEmpty() || documentId.startsWith("/")) return null
        if (documentId.split('/').any { it.isEmpty() || it == "." || it == ".." }) return null
        val base = root()
        val canonical = try {
            File(base, documentId).canonicalFile
        } catch (_: Exception) {
            return null
        }
        val rootCanonical = try {
            base.canonicalFile
        } catch (_: Exception) {
            return null
        }
        val under = canonical.path == rootCanonical.path ||
            canonical.path.startsWith(rootCanonical.path + File.separator)
        return canonical.takeIf { under }
    }

    private fun documentIdFor(parentId: String, name: String): String =
        if (parentId == ROOT_ID) name else "$parentId/$name"

    private fun parentIdOf(documentId: String): String {
        val slash = documentId.lastIndexOf('/')
        return if (slash < 0) ROOT_ID else documentId.substring(0, slash)
    }

    private fun validName(name: String): Boolean =
        name.isNotEmpty() && name != "." && name != ".." &&
            !name.contains('/') && !name.contains('\\') && name.length <= 255

    private fun mimeTypeFor(file: File): String {
        if (file.isDirectory) return DocumentsContract.Document.MIME_TYPE_DIR
        val ext = file.extension.lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
    }

    // ==== Cursor 构造 ====

    private fun include(projection: Array<out String>?, column: String): Boolean =
        projection == null || column in projection

    private fun documentCols(projection: Array<out String>?): List<String> {
        val cols = mutableListOf<String>()
        if (include(projection, DocumentsContract.Document.COLUMN_DOCUMENT_ID)) cols.add(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
        if (include(projection, DocumentsContract.Document.COLUMN_DISPLAY_NAME)) cols.add(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        if (include(projection, DocumentsContract.Document.COLUMN_MIME_TYPE)) cols.add(DocumentsContract.Document.COLUMN_MIME_TYPE)
        if (include(projection, DocumentsContract.Document.COLUMN_SIZE)) cols.add(DocumentsContract.Document.COLUMN_SIZE)
        if (include(projection, DocumentsContract.Document.COLUMN_LAST_MODIFIED)) cols.add(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
        if (include(projection, DocumentsContract.Document.COLUMN_FLAGS)) cols.add(DocumentsContract.Document.COLUMN_FLAGS)
        return cols
    }

    private fun documentRow(cols: List<String>, file: File, docId: String): List<Any?> =
        cols.map {
            when (it) {
                DocumentsContract.Document.COLUMN_DOCUMENT_ID -> docId
                DocumentsContract.Document.COLUMN_DISPLAY_NAME -> file.name
                DocumentsContract.Document.COLUMN_MIME_TYPE -> mimeTypeFor(file)
                DocumentsContract.Document.COLUMN_SIZE -> if (file.isFile) file.length() else null
                DocumentsContract.Document.COLUMN_LAST_MODIFIED -> file.lastModified()
                DocumentsContract.Document.COLUMN_FLAGS -> if (file.isDirectory) DIR_FLAGS else FILE_FLAGS
                else -> null
            }
        }

    /** 根文档（进入根目录那一屏）的列：没有大小，且名称用标题。 */
    private fun rootDocumentCols(projection: Array<out String>?): List<String> {
        val cols = mutableListOf<String>()
        if (include(projection, DocumentsContract.Document.COLUMN_DOCUMENT_ID)) cols.add(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
        if (include(projection, DocumentsContract.Document.COLUMN_DISPLAY_NAME)) cols.add(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        if (include(projection, DocumentsContract.Document.COLUMN_MIME_TYPE)) cols.add(DocumentsContract.Document.COLUMN_MIME_TYPE)
        if (include(projection, DocumentsContract.Document.COLUMN_LAST_MODIFIED)) cols.add(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
        if (include(projection, DocumentsContract.Document.COLUMN_FLAGS)) cols.add(DocumentsContract.Document.COLUMN_FLAGS)
        return cols
    }

    private fun rootDocumentRow(cols: List<String>): List<Any?> =
        cols.map {
            when (it) {
                DocumentsContract.Document.COLUMN_DOCUMENT_ID -> ROOT_ID
                DocumentsContract.Document.COLUMN_DISPLAY_NAME -> rootTitle()
                DocumentsContract.Document.COLUMN_MIME_TYPE -> DocumentsContract.Document.MIME_TYPE_DIR
                DocumentsContract.Document.COLUMN_LAST_MODIFIED -> root().lastModified()
                DocumentsContract.Document.COLUMN_FLAGS -> DIR_FLAGS
                else -> null
            }
        }

    private fun rootTitle(): String =
        appContext?.getString(R.string.documents_root_title) ?: "DSH home"

    private fun rootSummary(): String =
        appContext?.getString(R.string.documents_root_summary) ?: ""

    // ==== DocumentsProvider 实现 ====

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val cols = mutableListOf<String>()
        if (include(projection, DocumentsContract.Root.COLUMN_ROOT_ID)) cols.add(DocumentsContract.Root.COLUMN_ROOT_ID)
        if (include(projection, DocumentsContract.Root.COLUMN_DOCUMENT_ID)) cols.add(DocumentsContract.Root.COLUMN_DOCUMENT_ID)
        if (include(projection, DocumentsContract.Root.COLUMN_TITLE)) cols.add(DocumentsContract.Root.COLUMN_TITLE)
        if (include(projection, DocumentsContract.Root.COLUMN_SUMMARY)) cols.add(DocumentsContract.Root.COLUMN_SUMMARY)
        if (include(projection, DocumentsContract.Root.COLUMN_MIME_TYPES)) cols.add(DocumentsContract.Root.COLUMN_MIME_TYPES)
        if (include(projection, DocumentsContract.Root.COLUMN_ICON)) cols.add(DocumentsContract.Root.COLUMN_ICON)
        if (include(projection, DocumentsContract.Root.COLUMN_FLAGS)) cols.add(DocumentsContract.Root.COLUMN_FLAGS)
        if (include(projection, DocumentsContract.Root.COLUMN_AVAILABLE_BYTES)) cols.add(DocumentsContract.Root.COLUMN_AVAILABLE_BYTES)
        val cursor = MatrixCursor(cols.toTypedArray())
        cursor.addRow(
            cols.map {
                when (it) {
                    DocumentsContract.Root.COLUMN_ROOT_ID -> ROOT_ID
                    DocumentsContract.Root.COLUMN_DOCUMENT_ID -> ROOT_ID
                    DocumentsContract.Root.COLUMN_TITLE -> rootTitle()
                    DocumentsContract.Root.COLUMN_SUMMARY -> rootSummary()
                    DocumentsContract.Root.COLUMN_MIME_TYPES -> "*/*"
                    DocumentsContract.Root.COLUMN_ICON -> android.R.drawable.ic_menu_manage
                    DocumentsContract.Root.COLUMN_FLAGS -> ROOT_FLAGS
                    DocumentsContract.Root.COLUMN_AVAILABLE_BYTES -> root().usableSpace
                    else -> null
                }
            },
        )
        return cursor
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val cols = if (documentId == ROOT_ID) rootDocumentCols(projection) else documentCols(projection)
        val cursor = MatrixCursor(cols.toTypedArray())
        if (documentId == ROOT_ID) {
            cursor.addRow(rootDocumentRow(cols))
        } else {
            val file = fileFor(documentId) ?: throw FileNotFoundException("No document: $documentId")
            cursor.addRow(documentRow(cols, file, documentId))
        }
        return cursor
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val parent = fileFor(parentDocumentId) ?: throw FileNotFoundException("No directory: $parentDocumentId")
        if (!parent.isDirectory) throw FileNotFoundException("Not a directory: $parentDocumentId")
        val cols = documentCols(projection)
        val cursor = MatrixCursor(cols.toTypedArray())
        val children = (parent.listFiles() ?: emptyArray())
            .sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))
        for (child in children) {
            cursor.addRow(documentRow(cols, child, documentIdFor(parentDocumentId, child.name)))
        }
        cursor.setNotificationUri(
            requireNotNull(appContext).contentResolver,
            DocumentsContract.buildChildDocumentsUri(authority(), parentDocumentId),
        )
        return cursor
    }

    override fun queryRecentDocuments(rootId: String, projection: Array<out String>?): Cursor {
        val base = root()
        val cols = documentCols(projection)
        val cursor = MatrixCursor(cols.toTypedArray())
        if (base.isDirectory) {
            for (file in recentFiles(base)) {
                cursor.addRow(documentRow(cols, file, file.relativeTo(base).invariantSeparatorsPath))
            }
        }
        return cursor
    }

    /** 路径面包屑（Android 8.0+ 文件管理器）：返回从根到该文档的逐级 documentId 段。 */
    override fun findDocumentPath(parentDocumentId: String?, childDocumentId: String): DocumentsContract.Path {
        if (fileFor(childDocumentId) == null) throw FileNotFoundException("No document: $childDocumentId")
        val segments = if (childDocumentId == ROOT_ID) emptyList() else childDocumentId.split('/')
        // parentDocumentId（可为 null）只说明调用方的父文档上下文，路径按 childDocumentId 计算。
        return DocumentsContract.Path(ROOT_ID, segments)
    }

    /** 树选择（ACTION_OPEN_DOCUMENT_TREE）支持：child 必须在 parent 之下（或就是 parent 自身）。 */
    override fun isChildDocument(parentDocumentId: String, childDocumentId: String): Boolean {
        val parent = fileFor(parentDocumentId) ?: return false
        val child = fileFor(childDocumentId) ?: return false
        val p = parent.canonicalPath
        val c = child.canonicalPath
        return c == p || c.startsWith(p + File.separator)
    }

    override fun getDocumentType(documentId: String): String {
        val file = fileFor(documentId) ?: throw FileNotFoundException("No document: $documentId")
        return mimeTypeFor(file)
    }

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor {
        val file = fileFor(documentId) ?: throw FileNotFoundException("No document: $documentId")
        if (!file.isFile) throw FileNotFoundException("Not a file: $documentId")
        val pfdMode = when {
            mode.startsWith("rw") ->
                ParcelFileDescriptor.MODE_READ_WRITE or ParcelFileDescriptor.MODE_CREATE
            mode.startsWith("w") ->
                ParcelFileDescriptor.MODE_WRITE_ONLY or ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_TRUNCATE
            else -> ParcelFileDescriptor.MODE_READ_ONLY
        }
        return ParcelFileDescriptor.open(file, pfdMode)
    }

    override fun createDocument(parentDocumentId: String, displayName: String, mimeType: String): String {
        if (!validName(displayName)) throw FileNotFoundException("Invalid name: $displayName")
        val parent = fileFor(parentDocumentId) ?: throw FileNotFoundException("No parent: $parentDocumentId")
        if (!parent.isDirectory) throw FileNotFoundException("Not a directory: $parentDocumentId")
        val target = File(parent, displayName)
        if (target.exists()) throw FileNotFoundException("Already exists: $displayName")
        val created = if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
            target.mkdir()
        } else {
            try {
                target.createNewFile()
            } catch (_: java.io.IOException) {
                throw FileNotFoundException("Could not create: $displayName")
            }
        }
        if (!created) throw IllegalStateException("Could not create: $displayName")
        notifyChildren(parentDocumentId)
        return documentIdFor(parentDocumentId, displayName)
    }

    override fun renameDocument(documentId: String, displayName: String): String {
        if (documentId == ROOT_ID) throw UnsupportedOperationException("Cannot rename root")
        if (!validName(displayName)) throw FileNotFoundException("Invalid name: $displayName")
        val file = fileFor(documentId) ?: throw FileNotFoundException("No document: $documentId")
        val parent = file.parentFile ?: throw FileNotFoundException("No parent")
        val target = File(parent, displayName)
        if (target.exists()) throw FileNotFoundException("Already exists: $displayName")
        if (!file.renameTo(target)) throw IllegalStateException("Rename failed: $documentId")
        val parentId = parentIdOf(documentId)
        notifyChildren(parentId)
        return documentIdFor(parentId, displayName)
    }

    override fun deleteDocument(documentId: String) {
        if (documentId == ROOT_ID) throw UnsupportedOperationException("Cannot delete root")
        val file = fileFor(documentId) ?: throw FileNotFoundException("No document: $documentId")
        val parentId = parentIdOf(documentId)
        val deleted = if (file.isDirectory) file.deleteRecursively() else file.delete()
        if (!deleted) throw IllegalStateException("Delete failed: $documentId")
        notifyChildren(parentId)
    }

    // ==== 内部工具 ====

    /** 最近修改的文件（浅层、限量），供「最近」标签；避免遍历整个家目录树。 */
    private fun recentFiles(base: File, maxDepth: Int = 2, budget: Int = 200): List<File> {
        val found = mutableListOf<File>()
        fun walk(dir: File, depth: Int) {
            if (depth > maxDepth || found.size >= budget) return
            val entries = dir.listFiles() ?: return
            for (entry in entries) {
                if (found.size >= budget) return
                if (entry.isFile) found.add(entry) else if (entry.isDirectory) walk(entry, depth + 1)
            }
        }
        walk(base, 0)
        return found.sortedByDescending { it.lastModified() }.take(20)
    }

    /** 通知父目录内容变化，让文件管理器刷新列表。 */
    private fun notifyChildren(parentId: String) {
        val resolver: ContentResolver = requireNotNull(appContext).contentResolver
        val uri = if (parentId == ROOT_ID) {
            DocumentsContract.buildRootsUri(authority())
        } else {
            DocumentsContract.buildChildDocumentsUri(authority(), parentId)
        }
        resolver.notifyChange(uri, null)
    }
}
