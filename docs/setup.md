# Set up NetCrate

Use two Windows x64 computers: your source computer (called **Editing Computer** in setup) and another computer with enough backup storage. Keep both computers on and signed in to Windows while NetCrate runs. NetCrate resumes its background tasks when you sign in.

## On both computers

Open `NetCrate.exe` from the complete NetCrate folder. Keep its accompanying files together.

1. Answer **Which computer is this?** Choose **Editing Computer** or **Backup Server**.
2. Choose **Folder backups** (the default) for ordinary files, or **Backups and media processing** for video projects and returned proxies. On the Backup Server, select Folder backups for a Folder source; select media processing if the source requests proxies. A Folder-only server rejects a media request before code confirmation. Choose a source folder on the Editing Computer and separate backup storage on the Backup Server. Use ordinary local folders outside OneDrive and other linked folders.
3. Choose **Prepare this computer**. NetCrate downloads and verifies its tools. Folder backups skip the video tools and Pillow. The server still includes Python and bcrypt to create its private transport login. You do not need to install them or enter commands.
4. On the Backup Server, choose **Save recovery details**. Keep a separate copy on another computer or removable drive. This file unlocks your backups. Confirm that you saved that copy.
5. Continue to **Connect your computers**. Choose **Open NetBird** and sign in with the same NetBird account on both computers. Windows may ask you to approve its installation.

If the computers already connect through WireGuard, another private VPN, or the same local network, NetBird is optional. Expand **Use an existing private connection** on each computer, enter that computer's private IPv4 address, then choose **Use this connection**. NetCrate checks that the address belongs to that computer. An existing WireGuard tunnel must already provide connectivity between the locations; NetCrate does not configure routers or create that tunnel.

## Connect the computers

1. On the Editing Computer, choose **Save connection file**. Send that file to the Backup Server using a USB drive or a file transfer method you already use.
2. On the Backup Server, choose **Open connection file**. Compare its device code with the code on the Editing Computer. Choose **Codes match** only if they are identical. Approve the Windows request to allow the connection from your Editing Computer.
3. On the Backup Server, choose **Save reply file**. Send the reply to the Editing Computer.
4. On the Editing Computer, choose **Open reply file**. Compare its connection code with the code on the Backup Server. Choose **Codes match** if they are identical.
5. Choose **Check connection** on the Editing Computer, then on the Backup Server. Continue on both computers.

Connection files expire after 24 hours. If a code differs, stop and save a new connection file on the Editing Computer. The reply is encrypted for that computer, but should still be handled privately.

## Check the sample and start a backup

On the Editing Computer, choose **Run sample check**. Folder mode creates a text file, backs it up, restores a disposable copy and compares its bytes with the known original. Media mode backs up a generated video and verifies the returned proxy and contact sheet. Keep the Backup Server on and connected. You can finish its local setup while the Editing Computer runs the test.

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

You need the complete Windows x64 NetCrate build, the readable recovery file, the attached originals backup drive and enough free space in a separate local destination. Open NetCrate and, on the first setup screen before choosing a computer role, choose **Recover from a recovery file**. Choose the saved file and the drive's existing `originals` folder, normally inside `NetCrate-<installation id>\editing`. The drive letter may have changed. NetCrate verifies the backup identity against the saved recovery file; choosing a different backup or key fails without changing existing files.

This opens the same dated file browser. Recovery does not require the original source folder, Windows profile, pairing, setup, NetBird or media tools. The first recovery can download and verify the pinned PowerShell and Restic tools, so allow internet access for those downloads. It does not prepare or install the backup runtime, register background tasks, or save recovery passwords in setup state. Recovery passwords stay in memory and the child tool's environment.

Choose an ordinary fully available local destination outside the source, NetCrate state and backup storage. Links, special entries, unsupported Windows names and colliding names are refused. Files are recovered with private permissions for the recovering Windows account. Restoring a folder needs space for a private archive, the recovered tree and one file verification copy. Verification rereads each selected file, so large trees can take extra time. If Windows or the computer stops abruptly, an unpublished private `.netcrate-restore-…` folder may remain in the selected destination parent; existing output is preserved. Retry uses a new staging folder.

Automated local recovery tests cover moved backup paths and an absent source tree. Recovery with a separate physical computer/account and independent sign-in/reboot remains a separate acceptance check. Test a disposable recovery before relying on a new installation.
