copy file to your Jellyfin server
install sqlite3
install PowerShell
`chmod +x cleanup-media.ps1`
run `cleanup-media.ps1 -DryRun`
it will show you how many episodes and movies will get removed from the database
run `cleanup-media.ps1` without -DryRun
The script will ask you to stop Jellyfin
The script will ask you to make a snapshot of your VM/LXC/Container and asks you if it should backup your database
Then it will remove the files from the database
Restart jellyfin
