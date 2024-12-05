# Odd Package Manager - A rootless package manager, made to work with as little as possible

# WARNING
### THIS IS *ALPHA* SOFTWARE. EXPECT BREAKING CHANGES TO OCCUR WITHOUT NOTICE.

## Why?
I wanted to make a package manager that would support as many linux environments as possible, including embedded devices, or containers where you cannot get root.
## Installation
```bash
curl -sSL opm.oddbyte.dev/opminstall.sh > opminstall.sh && sh opminstall.sh
```
You can use `bash`, `sh`, or even `busybox ash` for the installer. Just replace sh with your desired shell.
You must keep it as a file, because it tries to read from stdin. So using a pipe to pipe the output from curl to sh or bash will break the installer. However, there is nothing stopping you from using `rm` to delete the installer script after.

## Features
- Runs on busybox, so it should run the same on all devices
- Custom repo support (Please DM me to get the backend software to run your own)
- Does not require root. All packages in the official repo do not require root to run.

## Usage
```
opm@oddbyte:~$ opm help
‏
‏=====================================
‏          OPM Package Manager
‏          By Oddbyte
‏=====================================
‏
‏Usage:
‏    opm [command] [options]
‏
‏Commands:
‏    help                                Show this help message
‏    install | add | i                   Install a package
‏    remove | uninstall | delete | rm    Remove a package
‏    repos                               List configured repositories
‏    addrepo [repo_url]                  Add a repository
‏    rmrepo [repo_url]                   Remove a repository
‏    list                                List all package names
‏    search [query]                      Search packages
‏    reinstall [package]                 Reinstalls the package, deleting all data.
‏    upgrade [package]                   Reinstalls the package, but keeps the config data.
‏    update                              Update OPM
‏    show [package]                      Show package details
‏    postinstall [package]               Run post-install script for a package
‏    enable [package]                    Enable the package's service
‏    disable [package]                   Disable the package's service
```
