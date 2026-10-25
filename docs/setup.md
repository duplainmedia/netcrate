# Set up NetCrate

Use two Windows x64 computers: your editing computer and another computer with enough storage for backups and proxies. Keep both computers on and signed in to Windows while NetCrate runs. NetCrate resumes its background tasks when you sign in.

## On both computers

Open `NetCrate.exe` from the complete NetCrate folder. Keep its accompanying files together.

1. Answer **Which computer is this?** Choose **Editing Computer** or **Backup Server**.
2. Choose a folder. On the Editing Computer, choose the folder containing your projects. On the Backup Server, choose backup storage. Use ordinary local folders outside OneDrive and other linked folders.
3. Choose **Prepare this computer**. NetCrate downloads and verifies its tools. You do not need to install Python or enter commands.
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

On the Editing Computer, choose **Run sample check**. NetCrate creates a small test project, backs it up, processes it on the server and verifies the returned proxy and contact sheet. Keep the Backup Server on and connected. You can finish its local setup while the Editing Computer runs the test.

When the check passes, choose **Open NetCrate**, then **Back up a project**. Select one project directly inside your chosen project folder. NetCrate backs it up and requests proxies automatically.

Returned files appear under `Proxies\NetCrate` inside that project, with a separate folder for each result version. **Open proxies** opens the selected version. NetCrate keeps earlier versions and does not prune backups automatically.

If a computer or drive disconnects, reconnect it and leave NetCrate running. Interrupted requests retry from their saved backup snapshot. Check that NetBird is connected and both Windows accounts are signed in if a job needs attention.

## Recovery

The recovery file contains the passwords and identities of both Restic repositories. Keep it separate from the backup drive. It can unlock the repositories without the original Windows account. Passwords saved inside NetCrate itself are protected for the Windows account that completed setup.

A full restore wizard and backup retention controls are not part of this build. Restic remains the independent recovery tool. Test recovery using a disposable backup before relying on a new installation.
