# Odd Package Manager - A rootless package manager, made to work with as little as possible
## Why?
I wanted to make a package manager that would support as many linux environments as possible, including embedded devices, or containers where you cannot get root.
## Installation
```bash
curl -sSL opm.oddbyte.dev/opminstall.sh > opminstall.sh && bash opminstall.sh
```
## Usage
```
opm@oddbyte:~$ opm help
=====================================
          OPM Package Manager
          By Oddbyte
=====================================

Usage:
    opm [command] [options]

Commands:
    help                                Show this help message
    install | add | i                   Install a package
    remove | uninstall | delete | rm    Remove a package
    repos                               List configured repositories
    addrepo [repo_url]                  Add a repository
    rmrepo [repo_url]                   Remove a repository
    list                                List all package names
    search [query]                      Search packages
    reinstall | upgrade [package]       Reinstall or upgrade a package
    update                              Update OPM
    show [package]                      Show package details
    postinstall [package]               Run post-install script for a package
```
