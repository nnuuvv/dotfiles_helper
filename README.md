# dotfile_helper

### Features

- new | set up a fresh repo in ~/dotfiles
- init | initialize symlinks based on existing ~/dotfiles repo
- init <link> | like init, but clones the supplied repo to ~/dotfiles first
- add <path> | add an existing dot file to the ~/dotfiles repo and set up the symlink
- add submodule <link> <path> | like add, but it will be added as a submodule 

TODO: builds and releases

---
#### Usage examples

Initial setup
```sh
gleam run new 
```

Adding a local config
```sh
gleam run add ~/.config/wezterm
```

Adding a config that is already tracked elsewhere
```sh
gleam run add submodule git@git.nuv.sh:nuv/nvim ~/.config/nvim
```
The link `git@git.nuv.sh:nuv/nvim` and the path `~/.config/nvim` are directly passed to  
`git submodule add <link> <path>` running in `~/dotfiles`


Setting up a new device with an existing dotfiles repo
```sh
gleam run init git@git.nuv.sh:nuv/dotfiles
```


