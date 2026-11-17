# Cooperative local-model admission

Status: development change, not a qualified helper integration.

Every production `ManagedLocalModelStore` uses the same Application Support model root. Its private, never-unlinked `.resource-admission.lock` file owns a nonblocking exclusive kernel `flock`. This serializes generation, download/repair, and removal across store instances and cooperating processes, including different catalog models. Internal custom-root initializers exist for tests; a future helper must use the production initializer, not a configured per-helper root.

The lease is acquired before installed-artifact verification and held through the awaited operation. Generation already cancels and joins its actual producer before releasing cache. Default GPU and CPU streams are synchronized before cache release, while admission remains held. Cancellation is a request to stop, not permission for a second process to start immediately. There is no stale PID, timeout lock stealing, or lock-file deletion. Process death releases the kernel descriptor lock. A busy lock and unsafe/unavailable lock are distinct refusals, neither bypassed.

The root is an owned non-group/world-writable directory opened without following a final symlink. The lock is opened relative to its descriptor, without following symlinks, with close-on-exec; it must be an owned private regular file with one link. The named lock inode is checked after acquisition. Existing permissions are not rewritten. Parent directory aliases that lead to the same root use the same inode; this is not a defense against a malicious same-user process replacing directory trees or modifying binaries. Do not unlink/replace the lock or model-root directory while any cooperating client runs. Root ownership and trusted installation are assumptions, not cryptographic application identity.

This admission mechanism cannot constrain older Imrse builds, other MLX applications, or noncooperating helpers. Before any future helper experiment, verify the legacy app has exited and launch only independently reviewed builds sharing this mechanism. This does not reserve RAM, GPU memory, disk, or prove a model fits available resources. Resource-budget preflight remains a separate prerequisite.

No listener, child helper, provider protocol, pairing credentials, remote fallback, downloads, or production model inference is added by this patch. The existing model store's user-requested download/remove operations retain their behavior but now participate in admission. A helper must remain local-only and produce a draft, never editor Apply authority.

Validation must include distinct-instance and real-process contention, release on return/error and process death, cancellation while cleanup remains pending, unsafe filesystem objects, unchanged ordinary local-model behavior, and independent review. Synthetic test fixtures are not actual MLX resource measurements.
