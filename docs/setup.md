# Set up NetCrate

NetCrate is experimental. Use disposable test data, keep independent backups, and read the [remaining issues and test plan](experimental-roadmap.md) before setup.

Use two Windows x64 computers: your source computer (called **Editing Computer** in setup) and another computer with enough backup storage. Keep both computers on and signed in to Windows while NetCrate runs. NetCrate resumes its background tasks when you sign in.

## On both computers

Open `NetCrate.exe` from the complete NetCrate folder. Keep its accompanying files together.

1. Answer **Which computer is this?** Choose **Editing Computer** or **Backup Server**.
2. Choose **Folder backups** (the default) for ordinary files, or **Backups and media processing** for video projects and returned proxies. On the Backup Server, select Folder backups for a Folder source; select media processing if the source requests proxies. A Folder-only server rejects a media request before code confirmation. Choose a source folder on the Editing Computer and separate backup storage on the Backup Server. Use ordinary local folders outside OneDrive and other linked folders.
3. Continue to Preparation and choose **Review software**. Review each tool's version, purpose, download source, license and location. Approve the listed software, then choose **Install and prepare**. NetCrate shows progress and verifies the downloads. Folder backups skip the video tools and Pillow. The server still needs Python and bcrypt for endpoint authentication. Private copies are installed for your Windows account; existing system versions are preserved. **Check again** refreshes the review without installing anything.
4. On the Backup Server, continue to the recovery page. Choose **Save recovery file** or **Copy recovery contents**. The complete document unlocks your backups. Save a separate accessible copy in secure storage, then confirm that you have done so. A password manager can hold the copied document. The clipboard copy excludes Windows history and cloud synchronization and clears after two minutes if still owned by NetCrate. **Clear clipboard now** clears it sooner.
5. Continue to Connection. If both computers already share a private local network or VPN, use that connection. Otherwise choose **Review NetBird options**. NetCrate shows the optional system installation for separate approval, then opens NetBird's sign-in UI. Use the same NetBird account on both computers.

Enter each computer's own private IPv4 address as the local address and the other computer's address as the peer. Select a discovered NetBird peer if available. NetCrate checks that the local address belongs to this computer. An existing WireGuard tunnel must already provide connectivity between locations; NetCrate does not configure routers or create that tunnel.

The folder page accepts an editable full path and offers a physical-drive picker. For example, create an ordinary folder such as `C:\NetCrateData` for source files or `C:\NetCrateBackups` for server storage. Windows may redirect Desktop and Documents to OneDrive; using their familiar names does not make them ordinary local folders. NetCrate does not change OneDrive or Windows folder redirection. Choose a path outside linked folders and keep source, storage and application folders separate.

You can save recovery details in an ordinary local C-drive folder outside NetCrate and backup storage. **Show file** reveals the saved location. If a separate copy is not available yet, **Continue with local copy** permits setup to continue and explains that losing this computer and its local copy can make recovery impossible. Local-only continuation does not claim that an independent copy exists. Existing recovery files are never overwritten.

## Connect the computers

1. On the Backup Server, review and approve temporary setup reception for the selected peer. Start reception and approve its Windows firewall request. This setup-only rule expires after 15 minutes and is removed when reception ends.
2. Start the connection on the Editing Computer. NetCrate exchanges the connection details automatically. Keep both setup windows open.
3. Compare the **device code** on both screens. On the Backup Server, choose **Codes match** only if they are identical. Approve the separate Windows request for the persistent backup endpoint.
4. Compare the **connection code** on both screens. On the Editing Computer, choose **Codes match** only if they are identical.
5. NetCrate checks the actual backup repositories and signed acknowledgment automatically. Continue when the screen confirms the computers are connected. A waiting message names which computer needs attention.

If a code differs, stop. Do not approve it. Check the selected computers and addresses before starting again. A lost connection can resume from the existing exchange. If setup offers renewal after expiry, use its explicit start-again action; it preserves existing backup identities.

If automatic exchange is unavailable, use **manual file exchange** on the Connection page. Apply each computer's own private address first. The Editing Computer saves a connection file; transfer it privately by USB or a trusted file-transfer method and open it on the Backup Server. Compare and confirm the device code there, then save its reply. Transfer the reply back, open it on the Editing Computer and compare and confirm the connection code. Check the connection on both computers. The on-screen instructions show the current step. Connection files expire after 24 hours; replies are encrypted for the requesting computer. Keep these files private.

## Check the sample and start a backup

On the Editing Computer, choose **Test backup and finish**. Folder mode creates a text file, backs it up, restores a disposable copy and compares its bytes with the known original. Media mode backs up a generated video and verifies the returned proxy and contact sheet. Successful verification finishes setup automatically. On the Backup Server, choose **Finish server setup**, then keep it on, signed in and connected while the Editing Computer tests the sample. Its completion page does not claim that the source sample has already passed.

When the check passes, choose **Open NetCrate**. In Folder mode, choose **Back up a folder** and select your configured source folder itself or any folder inside it. The dashboard shows **Backed up** after the original backup succeeds; no media repository or proxy processing is needed to complete that job. Files in folders named `Proxies` are ordinary originals in this mode.

In Media mode, choose **Back up a project** and select one project directly inside your chosen project folder. NetCrate backs it up and requests proxies automatically. Original completion is saved independently: a later proxy or transport failure keeps the successful snapshot and time available for retry. **Proxies ready** means the returned media has also passed verification.

Returned files appear under `Proxies\NetCrate` inside that project, with a separate folder for each result version. **Open proxies** opens the selected version. NetCrate keeps earlier versions and does not prune backups automatically.

If a computer or drive disconnects, reconnect it and leave NetCrate running. Interrupted requests retry from their saved backup snapshot. Check that NetBird is connected and both Windows accounts are signed in if a job needs attention.

Linked paths, online-only or offline placeholders and folders overlapping NetCrate's application or backup storage are unsupported. Make cloud files fully local and choose a separate ordinary folder. Locked or unreadable files fail the backup and retry; a partial Restic snapshot is not reported as a completed backup. Existing installations without a saved mode keep their Media behavior. Repair requires their original folder and mode.

## Automatic backups and backup status

On the source dashboard, choose **Automatic backups**, then **Choose folder**. Folder mode accepts the configured folder itself or a contained folder; Media mode accepts one direct child project. Enter one daily local time in **HH:mm**, leave **Enabled** checked and choose **Save schedule**. Select an existing row to change its time or enabled setting, or choose **Disable schedule**. The row shows the next full date, time, UTC offset and Windows time zone. An overdue run says **Catch-up pending** and retains its due date until it is queued, including while its folder is disconnected. The open window refreshes status and zone information every 30 seconds while preserving unsaved edits and action errors. Errors remain visible so you can correct the folder or time and retry.

The first run is the next occurrence after you save. After several missed days, NetCrate queues one catch-up backup of the folder's current contents, then resumes daily runs. If the folder is unavailable, reconnect it; other folders continue. A spring clock change runs a skipped minute at the next valid local minute. A repeated autumn hour runs once for that local date. Changing Windows time zone uses the new local time for future dates; already consumed local dates do not run again. Editing a schedule changes future admissions; work already queued or running may finish. A manual backup and a due schedule for the same folder share an active originals job. Completed originals allow a new backup while older media is still pending.

Both computers must stay on, signed in to Windows and connected. Closing the app leaves the existing signed-in background runtime working. Signing out stops that runtime; there is no signed-out service and schedules do not create additional Windows tasks. Windows time-zone changes take effect on the next background pass. A disconnected source folder gets a reconnect hint; queue or local state-storage failures instead ask you to check NetCrate's state-folder access, free space and queue records. Correct the problem or repair NetCrate, then retry.

Select a folder in the dashboard to see **Latest attempt** separately from **Last successful original** and **Media**. Dates include the full date, offset and local zone. A later queued or failed attempt does not hide an earlier successful original. Older checkpoints without a reliable successful-backup timestamp say **time unknown**. Media pending or needing attention does not change the successful originals result.

## Restore files

On the source dashboard, choose **Restore files**. Choose a dated backup, then double-click a folder (or press Enter) to browse its immediate contents. The breadcrumb returns to the whole backup or any parent folder. Select one file or folder, or leave nothing selected to restore the folder shown in the breadcrumb. **More** loads another page when needed. Each date page checks at most 50 candidate backups; opening a date checks that backup directly. Browsing can be cancelled by closing its window. A slow browse has a 30-minute total budget, shared by its metadata reads; reconnect the drive or private connection and choose Refresh if it times out.

Choose **Restore to a new folder**, select an existing local parent folder, then review the source, backup date, selection and new folder name. NetCrate restores privately, verifies the file bytes and publishes a separate `Recovered-…` folder. Existing files are preserved; a name collision gets a new suffix. The completed screen shows the verified output location and **Open recovered folder**. Keep the window open during restoration; large restores can take a long time. If a drive disconnects or verification fails, reconnect it and retry. Nothing is merged into an existing folder.

New backups appear only after their completion receipt is saved in the originals backup. An interrupted upload may need the source computer to retry before that date appears. Historical media backups without completion evidence are marked **Unknown (legacy)**; their original date and source folder come from the backup itself.

## Recover on another computer or Windows account

Keep a readable copy of the saved recovery file in secure offline storage, separate from the backup drive. It contains the keys that unlock your files. Its Windows permissions initially allow the exporting account only: before losing that account, make and verify a readable secure offline copy using an authorized storage or account-transfer method. A different account may need an authorized owner or administrator to grant access to that copy and to the attached backup drive. NetCrate does not change the original backup drive's permissions for you.

You need the complete Windows x64 NetCrate build, the complete recovery document, the attached originals backup drive and enough free space in a separate local destination. On the first setup screen before choosing a role, choose recovery from a file or pasted contents. Review and approve the pinned recovery tools if they are missing. For paste recovery, explicitly paste the complete saved document; it stays in memory. Choose the drive's existing `originals` folder, normally inside `NetCrate-<installation id>\editing`. The drive letter may have changed. NetCrate verifies the backup identity against the document; choosing a different backup or key fails without changing existing files.

This opens the same dated file browser. Recovery does not require the original source folder, Windows profile, pairing, setup, NetBird or media tools. The first recovery can download and verify the approved PowerShell and Restic tools, so allow internet access for those downloads. It does not prepare the backup runtime, register background tasks, or save recovery passwords in setup state. Recovery passwords stay in memory and the child tool's environment.

Choose an ordinary fully available local destination outside the source, NetCrate state and backup storage. Links, special entries, unsupported Windows names and colliding names are refused. Files are recovered with private permissions for the recovering Windows account. Restoring a folder needs space for a private archive, the recovered tree and one file verification copy. Verification rereads each selected file, so large trees can take extra time. If Windows or the computer stops abruptly, an unpublished private `.netcrate-restore-…` folder may remain in the selected destination parent; existing output is preserved. Retry uses a new staging folder.

Automated local recovery tests cover moved backup paths and an absent source tree. Recovery with a separate physical computer/account and independent sign-in/reboot remains a separate acceptance check. Test a disposable recovery before relying on a new installation.

## Storage checks and retention

On the Backup Server dashboard, open **Backup storage**. The window shows free space on the owning drive and warns when less than 5 GiB is available. **Check repositories now** queues a check of both originals and Results on the signed-in Backup Server. The latest attempt and last successful check are shown separately. This check verifies repository structure and metadata; it does not read every stored file's data. If a drive is unavailable, saved check and operation history remains visible; reconnect the drive and retry. A check can be queued while storage is unavailable, but retention stays disabled until both repositories are verified. If another operation holds a repository lock, wait and try again.

Retention starts at **Keep all backups**. To choose a different policy, select **Keep latest per folder**, enter a whole number of at least one, and choose **Preview retention**. Review the listed dates, folders and protection reasons before choosing **Confirm this preview** and confirming the separate prompt. Previews expire after 15 minutes and cannot be reused. If backups or dependency records change, create a fresh preview. Closing the window or saving a policy does not remove anything, and NetCrate never schedules deletion in the background.

This experimental build limits a preview to 256 positively completed Folder originals and at most 256 removals. It preserves the newest backup in each folder, Media and legacy originals, unknown or incomplete originals, completion and control records, all Results snapshots, and originals needed by validated requests or generated media. It refuses deletion when it cannot establish the required repository or dependency evidence. The list shows dates and counts rather than exact space savings because backups can share stored data. During confirmed maintenance the server temporarily stops its append-only endpoint and restarts it afterward. Keep the Backup Server on and signed in until the displayed operation finishes.

If removal was verified but cleanup stopped, select **Complete interrupted cleanup**, choose **Preview retention**, and review a fresh confirmation. This finishes cleanup without repeating removal. Ambiguous or conflicting journals block that action and remain visible for investigation.
