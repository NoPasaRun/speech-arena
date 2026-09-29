"""Make Godot's web preloader resume interrupted downloads.

Stock loadFetch() restarts a file from byte 0 on every retry, and a stream
error in the middle of the body (e.g. ERR_NETWORK_CHANGED) is swallowed, so
the page hangs instead of retrying at all. For a 100+ MB .pck that means a
flaky connection never finishes loading.

The replacement keeps the bytes already received and asks only for the rest
with a Range request. Per the Fetch spec, a request with Range is sent with
Accept-Encoding: identity, so GitHub Pages answers with uncompressed bytes
and the offset matches what we have counted. If the server ignores Range
(200 instead of 206), we drop the partial data and start over.

Fails loudly if the Godot template changed and the original code is gone.
"""
import sys

ORIGINAL = """	function getTrackedResponse(response, load_status) {
		function onloadprogress(reader, controller) {
			return reader.read().then(function (result) {
				if (load_status.done) {
					return Promise.resolve();
				}
				if (result.value) {
					controller.enqueue(result.value);
					load_status.loaded += result.value.length;
				}
				if (!result.done) {
					return onloadprogress(reader, controller);
				}
				load_status.done = true;
				return Promise.resolve();
			});
		}
		const reader = response.body.getReader();
		return new Response(new ReadableStream({
			start: function (controller) {
				onloadprogress(reader, controller).then(function () {
					controller.close();
				});
			},
		}), { headers: response.headers });
	}

	function loadFetch(file, tracker, fileSize, raw) {
		tracker[file] = {
			total: fileSize || 0,
			loaded: 0,
			done: false,
		};
		return fetch(file).then(function (response) {
			if (!response.ok) {
				return Promise.reject(new Error(`Failed loading file '${file}'`));
			}
			const tr = getTrackedResponse(response, tracker[file]);
			if (raw) {
				return Promise.resolve(tr);
			}
			return tr.arrayBuffer();
		});
	}
"""

REPLACEMENT = """	// Patched by .github/scripts/patch_preloader.py: resumable downloads.
	const partialDownloads = {};

	function loadFetch(file, tracker, fileSize, raw) {
		const part = partialDownloads[file] || (partialDownloads[file] = { chunks: [], loaded: 0, contentType: '' });
		const status = tracker[file] || (tracker[file] = { total: fileSize || 0, loaded: 0, done: false });
		const init = part.loaded > 0 ? { headers: { 'Range': `bytes=${part.loaded}-` } } : {};
		return fetch(file, init).then(function (response) {
			if (!response.ok) {
				return Promise.reject(new Error(`Failed loading file '${file}'`));
			}
			if (part.loaded > 0 && response.status !== 206) {
				part.chunks = [];
				part.loaded = 0;
			}
			part.contentType = part.contentType || response.headers.get('Content-Type') || '';
			const reader = response.body.getReader();
			function pump() {
				return reader.read().then(function (result) {
					if (result.value) {
						part.chunks.push(result.value);
						part.loaded += result.value.length;
						status.loaded = part.loaded;
					}
					return result.done ? null : pump();
				});
			}
			return pump();
		}).then(function () {
			const bytes = new Uint8Array(part.loaded);
			let offset = 0;
			part.chunks.forEach(function (chunk) {
				bytes.set(chunk, offset);
				offset += chunk.length;
			});
			delete partialDownloads[file];
			status.done = true;
			if (raw) {
				return new Response(bytes, { headers: { 'Content-Type': part.contentType || 'application/wasm' } });
			}
			return bytes.buffer;
		});
	}
"""

# With resume, a retry costs nothing already downloaded: allow ~1 min of outage.
ATTEMPTS = ("\tconst DOWNLOAD_ATTEMPTS_MAX = 4;\n", "\tconst DOWNLOAD_ATTEMPTS_MAX = 60;\n")

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    src = f.read()
for old, new in [(ORIGINAL, REPLACEMENT), ATTEMPTS]:
    if src.count(old) != 1:
        sys.exit(f"preloader patch not applied: expected code not found in {path}")
    src = src.replace(old, new)
with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print(f"patched {path}")
