package com.fastory.sdk

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import java.io.File
import java.io.FileNotFoundException
import java.security.InvalidAlgorithmParameterException
import java.security.KeyStore
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import javax.crypto.BadPaddingException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Where the refresh-token store gets its AES-GCM key and cipher. Production holds the key in the
 * Android Keystore, where it never leaves the device.
 */
internal interface RefreshTokenKeySource {
    fun key(): SecretKey

    fun cipher(): Cipher

    /** Drops a key the platform invalidated, so that the next write starts over with a new one. */
    fun discardKey() {}
}

internal object AndroidKeyStoreRefreshTokenKey : RefreshTokenKeySource {
    private const val PROVIDER = "AndroidKeyStore"
    private const val ALIAS = "com.fastory.sdk.refresh-token"

    @Synchronized
    override fun key(): SecretKey {
        (keyStore().getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    override fun cipher(): Cipher = Cipher.getInstance("AES/GCM/NoPadding")

    @Synchronized
    override fun discardKey() {
        keyStore().deleteEntry(ALIAS)
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }
}

/**
 * What reading the stored refresh token found. [Retry] reached no answer, so it is never a missing
 * token: the caller tries again rather than signing the fan out (SPEC § 7.5).
 */
internal sealed class RefreshTokenReadResult {
    data class Present(val token: String) : RefreshTokenReadResult()

    object Absent : RefreshTokenReadResult()

    object Retry : RefreshTokenReadResult()
}

internal data class StoredRefreshToken(val account: String, val token: String)

internal sealed class RefreshTokenOperationResult {
    object Done : RefreshTokenOperationResult()

    object Retry : RefreshTokenOperationResult()
}

/**
 * Keeps a `FanId` fan's refresh token on the device (SPEC § 7.5): one file per configuration stamp
 * in the app's no-backup files directory, so it is never restored onto another device, encrypted
 * with an AES-GCM key whose IV the cipher generates at every write.
 *
 * Only a token that is not there, or data that no longer decrypts under its key, reads as absent —
 * and is purged. Any other failure, such as a Keystore that fails for a moment, reads as
 * [RefreshTokenReadResult.Retry] and leaves the file alone. The Keystore and the disk can block, so
 * every operation runs on [executor], in submission order, and each callback is delivered on the
 * main thread.
 */
internal class RefreshTokenStore(
    context: Context,
    private val keySource: RefreshTokenKeySource = AndroidKeyStoreRefreshTokenKey,
    private val executor: Executor = sharedExecutor,
) {
    private val context: Context = context.applicationContext ?: context
    private val main = Handler(Looper.getMainLooper())

    fun read(account: String, callback: (RefreshTokenReadResult) -> Unit) {
        submit(callback, RefreshTokenReadResult.Retry) { readNow(account) }
    }

    fun otherAccounts(keeping: String, callback: (List<StoredRefreshToken>) -> Unit) {
        submit(callback, emptyList()) {
            storedAccounts().filter { it != keeping }.mapNotNull { other ->
                (readNow(other) as? RefreshTokenReadResult.Present)?.let { StoredRefreshToken(other, it.token) }
            }
        }
    }

    /** Stores [token] for [account], replacing the one already there. */
    fun write(
        token: String,
        account: String,
        callback: (RefreshTokenOperationResult) -> Unit = {},
    ) {
        submit(callback, RefreshTokenOperationResult.Retry) {
            val blob = try {
                encrypt(token)
            } catch (e: Exception) {
                if (!e.meansKeyInvalidated()) throw e
                discardKeyQuietly()
                encrypt(token)
            }
            val file = fileOf(account)
            file.baseFile.parentFile?.mkdirs()
            val stream = file.startWrite()
            try {
                stream.write(blob)
                file.finishWrite(stream)
            } catch (e: Exception) {
                file.failWrite(stream)
                throw e
            }
            RefreshTokenOperationResult.Done
        }
    }

    /**
     * Reads the token of [account] and removes it in one queued operation, handing back what was
     * read — so a token let go before anyone read it can still be revoked. The token is removed even
     * when it could not be read.
     */
    fun take(account: String, callback: (String?) -> Unit) {
        submit(callback, null) {
            val found = try {
                readNow(account)
            } catch (_: Exception) {
                RefreshTokenReadResult.Retry
            }
            fileOf(account).delete()
            (found as? RefreshTokenReadResult.Present)?.token
        }
    }

    /** Removes the token of [account] alone. An already missing token is erased too. */
    fun erase(account: String, callback: (RefreshTokenOperationResult) -> Unit = {}) {
        submit(callback, RefreshTokenOperationResult.Retry) {
            val file = fileOf(account)
            file.delete()
            if (file.baseFile.exists()) RefreshTokenOperationResult.Retry else RefreshTokenOperationResult.Done
        }
    }

    private fun <T> submit(callback: (T) -> Unit, onFailure: T, operation: () -> T) {
        executor.execute {
            val result = try {
                operation()
            } catch (_: Exception) {
                onFailure
            }
            main.post { callback(result) }
        }
    }

    private fun readNow(account: String): RefreshTokenReadResult {
        val file = fileOf(account)
        try {
            val token = decrypt(file.readFully())
            if (!token.isNullOrEmpty()) return RefreshTokenReadResult.Present(token)
        } catch (_: FileNotFoundException) {
            return RefreshTokenReadResult.Absent
        } catch (e: Exception) {
            if (!e.meansUndecryptable()) return RefreshTokenReadResult.Retry
            if (e.meansKeyInvalidated()) discardKeyQuietly()
        }
        file.delete()
        return RefreshTokenReadResult.Absent
    }

    private fun directory(): File = File(context.noBackupFilesDir, DIRECTORY)

    private fun fileOf(account: String): AtomicFile = AtomicFile(File(directory(), nameOf(account)))

    private fun nameOf(account: String): String =
        Base64.encodeToString(account.toByteArray(Charsets.UTF_8), NAME_ENCODING)

    private fun storedAccounts(): List<String> = directory().list().orEmpty().mapNotNull(::accountOf)

    private fun accountOf(name: String): String? {
        val account = try {
            String(Base64.decode(name, NAME_ENCODING), Charsets.UTF_8)
        } catch (_: IllegalArgumentException) {
            return null
        }
        return account.takeIf { nameOf(it) == name }
    }

    private fun encrypt(token: String): ByteArray {
        val key = keySource.key()
        val cipher = keySource.cipher()
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val iv = cipher.iv
        val sealed = cipher.doFinal(token.toByteArray(Charsets.UTF_8))
        return byteArrayOf(FORMAT, iv.size.toByte()) + iv + sealed
    }

    /** Null when the blob is not one this store wrote. */
    private fun decrypt(blob: ByteArray): String? {
        if (blob.size < HEADER_BYTES || blob[0] != FORMAT) return null
        val ivLength = blob[1].toInt() and 0xFF
        val sealedStart = HEADER_BYTES + ivLength
        if (ivLength == 0 || blob.size < sealedStart + TAG_BYTES) return null
        val key = keySource.key()
        val cipher = keySource.cipher()
        cipher.init(
            Cipher.DECRYPT_MODE,
            key,
            GCMParameterSpec(TAG_BYTES * 8, blob.copyOfRange(HEADER_BYTES, sealedStart)),
        )
        return String(cipher.doFinal(blob, sealedStart, blob.size - sealedStart), Charsets.UTF_8)
    }

    private fun discardKeyQuietly() {
        try {
            keySource.discardKey()
        } catch (_: Exception) {
        }
    }

    private fun Throwable.meansKeyInvalidated(): Boolean =
        generateSequence(this) { it.cause }.any { it is KeyPermanentlyInvalidatedException }

    private fun Throwable.meansUndecryptable(): Boolean =
        meansKeyInvalidated() || this is BadPaddingException || this is InvalidAlgorithmParameterException

    private companion object {
        const val DIRECTORY = "com.fastory.sdk.refresh-token"
        const val FORMAT: Byte = 1
        const val HEADER_BYTES = 2
        const val TAG_BYTES = 16
        const val NAME_ENCODING = Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP

        val sharedExecutor: Executor by lazy { Executors.newSingleThreadExecutor() }
    }
}
