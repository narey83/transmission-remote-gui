# Show remote downloads in Finder

Mount the daemon's download shares on your Mac first (for example, using Finder's
**Go → Connect to Server**). This feature only translates paths; it does not mount
shares, copy/move files, change the daemon's download directories, or launch files.

## Configure each server

Open **Settings → Servers → Edit → Path Mappings**. Add a remote download folder
and the corresponding local folder. **Browse…** selects an existing local folder;
**Paste Mappings…** imports the classic transgui format, one `remote=local` rule per
line. Imports append to existing mappings and reject duplicate remote folders.

For example:

```text
/srv/downloads/movies=/Volumes/Movies
/srv/downloads/电视=/Volumes/电视
```

Paths must be absolute POSIX paths. Spaces and Unicode names are preserved;
trailing slashes are optional. Rules match complete directory components, and the
most specific matching remote folder wins. `/srv/downloads` does not match
`/srv/downloads2`. Repeated remote roots and `.` / `..` components are rejected.
Mappings are stored with that server in the existing Application Support
configuration, outside the app bundle, so replacing the app normally preserves
them. Older configurations without mappings continue to work.

The Add torrent dialog also offers each mapping's **remote folder** in its **Save to**
menu. Selecting one sets the destination for that torrent only; the daemon's default
folder stays unchanged. This does not require the local share to be mounted. With no
mappings, the menu is hidden and you can still enter a server path manually. Finder
opens, magnet links and drops all show the confirmation dialog before submitting.

## Reveal a torrent

Right-click a torrent and choose **Show in Finder** (the item is only in the menu
when the current server has at least one mapping). The action selects a single
file or a multi-file torrent's top-level folder in Finder. For torrents with files
directly in the download directory, it selects that directory. Multiple selected
torrents can be revealed together; every target must resolve successfully before
Finder is activated. The displayed torrent name is not used to guess file paths:
the daemon's current file list and download directory are queried instead.

**Double-click behaviour is unchanged.** Download completion is not required, but
the mapped data must already exist. Magnet links without file metadata cannot be
resolved yet. Partially downloaded files with a different on-disk name (such as a
`.part` suffix) are not guessed.

Missing mappings, unmounted `/Volumes` shares, unavailable files, permission
errors and slow shares have distinct messages. Filesystem checks run off the main
thread with an eight-second deadline; late responses never activate Finder.
Symlinks escaping the mapped local root are refused. If macOS mounts a share under
a different name (for example, `/Volumes/Movies-1`), update the local mapping.

This feature sends only a read-only `torrent-get` request. It does not start, stop,
rename, move or delete torrents. A server switch or replaced torrent invalidates
an outstanding reveal request.

## Verification

`swift run KitTests` includes parser, boundary/longest-match, Unicode/literal
filename, content-root, configuration compatibility, context-menu and read-only
filesystem tests. `swift run LocalizationTests` checks all supported UI languages.
`Scripts/uitest/test_path_mappings.py` uses an isolated app identity and a read-only
loopback mock, never the user's saved server configuration or real torrents.
Its automated mode requires the existing UI-test harness's accessibility helper
(`TRGUI UITest Helper.app`). Use `--interactive` to inspect the same fixtures with
native UI automation or manually when that helper is not installed.

## Copy completed downloads to this Mac

Select finished torrents and choose **Copy to This Mac…** from their context menu, then choose a local destination. The share must already be mounted and its path mapping configured, just as for Show in Finder. Transmission RPC supplies the file list; the app copies those files through the mounted share. It does not install a local torrent engine or require a new service on the server.

Only completed, wanted files are copied. Server files are left in place. Existing local files are never overwritten: a numbered name is used instead. Cancelling removes unpublished partial files; any earlier torrents that finished copying stay available in Finder.

### Automatically copy from Add Torrent

Tick **Copy to this Mac when finished** in the Add Torrent window, choose a local destination with **Browse…**, and choose what happens **After copying**:

- **Keep on server** is the default. The remote torrent and files remain available for seeding.
- **Delete torrent and files from server** removes the remote torrent and its data only after the local copy is published and checked byte for byte against every current remote file. All files must be selected; an excluded file prevents deletion.

The torrent still downloads on the selected server first. Keep the app open and the share mounted for automatic copying, or reopen the app and connect to that server later. Waiting requests are saved locally and resume after restart. If the share is unavailable, reconnect it and use **Retry** in **View → Copies to this Mac**. A shortcut at the bottom of the main window appears only while copies are unfinished or need attention; its count excludes completed history. Progress, the saved local path, failures and completed history are available from the View menu. Removing an entry only cancels the copy request or clears its history; it does not delete files.

Requests are bound to the original server, torrent hash and path mappings. A changed configuration requires setting up the copy again. Interrupted copies require checking for a local copy before retrying, since a crash may have happened just after publishing. A failed or interrupted server cleanup is never retried automatically; inspect the local and server files before taking further action. If the server disconnects while processing a delete request, its result can be uncertain. No local file is removed to compensate for a server error.
