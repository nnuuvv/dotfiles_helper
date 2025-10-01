import argv
import envoy
import filepath
import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import shellout
import simplifile

/// location, relative to $HOME, of the dotfiles repo
const dotfiles = "dotfiles"

pub fn main() -> Nil {
  let program_args = argv.load().arguments
  let assert Ok(home_dir) = envoy.get("HOME") as "$HOME not defined"

  case program_args {
    ["help"] -> show_help()
    ["new"] -> {
      let _ =
        setup_new(home_dir)
        |> result.map_error(describe_error)
        |> result.map_error(io.println_error)

      Nil
    }

    ["init", link] -> {
      let _ =
        init_from_link(link, home_dir)
        |> result.map_error(describe_error)
        |> result.map_error(io.println_error)

      Nil
    }
    ["init"] -> {
      let _ =
        update_symlinks(home_dir)
        |> result.map_error(describe_error)
        |> result.map_error(io.println_error)

      Nil
    }
    ["add", "submodule", link, path] -> {
      let _ =
        add_submodule(home_dir, link, path)
        |> result.map_error(describe_error)
        |> result.map_error(io.println_error)
      Nil
    }
    ["add", ..rest] -> {
      let _ =
        add_many(home_dir, rest)
        |> result.map_error(describe_error)
        |> result.map_error(io.println_error)
      Nil
    }
    _ -> show_help()
  }
}

// errors -----------------------------------------------------------------------

type InternalError {
  FailedToCopy(path: String, error: simplifile.FileError)
  FailedToRead(path: String, error: simplifile.FileError)
  FailedToWrite(path: String, error: simplifile.FileError)
  FileNotInHomeDirectory(file: String)
  FailedToCreateSymlink(#(Int, String))
  FailedToDecode(json.DecodeError)
  FailedToCloneRepo(#(Int, String))
  FailedToInitRepo(#(Int, String))
  FailedToCreateDir(path: String, error: simplifile.FileError)
  InsufficientPermissions(path: String, error: simplifile.FileError)
  FileWasSymlink(String)
}

fn describe_error(error: InternalError) {
  case error {
    FailedToCloneRepo(_) -> string.inspect(error)
    FailedToCopy(path, inner) ->
      string.inspect(error)
      <> " "
      <> path
      <> " "
      <> simplifile.describe_error(inner)
    FailedToCreateSymlink(_) -> string.inspect(error)
    FailedToDecode(_) -> string.inspect(error)
    FailedToRead(path, inner) ->
      string.inspect(error)
      <> " "
      <> path
      <> " "
      <> simplifile.describe_error(inner)
    FailedToWrite(path, inner) ->
      string.inspect(error)
      <> " "
      <> path
      <> " "
      <> simplifile.describe_error(inner)
    FileNotInHomeDirectory(_) -> string.inspect(error)
    FailedToCreateDir(path, inner) ->
      string.inspect(error)
      <> " "
      <> path
      <> " "
      <> simplifile.describe_error(inner)
    InsufficientPermissions(path, inner) ->
      string.inspect(error)
      <> " "
      <> path
      <> " "
      <> simplifile.describe_error(inner)
    FailedToInitRepo(_) -> string.inspect(error)
    FileWasSymlink(path) -> path <> " is a symlink. It will be skipped."
  }
}

// ------------------------------------------------------------------------------
// actions 
// ------------------------------------------------------------------------------

// new 

fn setup_new(home_dir: String) {
  let path = filepath.join(home_dir, dotfiles)
  use _ <- result.try(
    simplifile.create_directory(path)
    |> result.map_error(FailedToCreateDir(path, _)),
  )

  shellout.command(run: "git", with: ["init"], in: path, opt: [])
  |> result.map_error(FailedToInitRepo)
}

// init <link> ------------------------------------------------------------------

/// git clone's the provided link and then runs normal setup
///
fn init_from_link(link: String, home: String) {
  use _ <- result.try(clone_repo(link, home))
  update_symlinks(home)
}

fn clone_repo(link: String, home: String) {
  shellout.command(
    run: "git",
    with: ["clone", "--recurse-submodules", link, filepath.join(home, dotfiles)],
    in: ".",
    opt: [],
  )
  |> result.map_error(FailedToCloneRepo)
}

// init -------------------------------------------------------------------------

/// loads specs from spec.json and tries to create the symlinks based on it
///
fn update_symlinks(home home: String) -> Result(List(String), InternalError) {
  use specs <- result.try(
    spec_path(home)
    |> load_specs,
  )

  specs
  |> list.map(make_symlink_from_spec(_, home))
  |> list.map(result.map(_, string.inspect))
  |> result.all()
}

// add submodule <link> ---------------------------------------------------------

fn add_submodule(home: String, link: String, config_path: String) {
  use spec <- result.try(spec_from_config_path(config_path))

  use _ <- result.try(
    shellout.command(
      run: "git",
      with: [
        "submodule",
        "add",
        link,
        // drop `dotfiles` from `dotfiles/dot_config/nvim`
        spec.dotfiles_path |> drop_first_dir,
      ],
      in: filepath.join(home, dotfiles),
      opt: [],
    )
    |> result.map_error(FailedToCloneRepo),
  )

  use _ <- result.try(make_symlink_from_spec(spec, home))
  persist_spec(spec, home)
}

/// drops the first directory from a path
///
fn drop_first_dir(path: String) {
  filepath.split(path)
  |> list.drop(1)
  |> list.fold("", filepath.join)
}

fn show_help() {
  io.println(
    "
help -> show this
new -> set up a fresh ~/dotfiles repo
init -> initial setup of symlinks from ~/dotfiles to actual file locations
init <link> -> like init, but clones the specified repo to ~/dotfiles as well
add <path> -> add new config directory or file
add submodule <link> <path> -> where <path> is the target path i.e. `~/.config/nvim`
  ",
  )
}

/// add a list of new configs
///
fn add_many(home: String, configs: List(String)) {
  configs
  |> list.map(spec_from_config_path)
  |> list.map(result.try(_, move_config_to_dotfiles(_, home)))
  |> list.map(result.try(_, make_symlink_from_spec(_, home)))
  |> list.map(result.map_error(_, describe_error))
  |> list.map(result.map_error(_, io.println_error))
  |> result.values()
  |> persist_specs(home)
}

/// Moves the `target_path` to `dotfiles_path` using simplifile.rename
/// Returns the original spec
///
fn move_config_to_dotfiles(spec: Spec, home) {
  let full_target_path = filepath.join(home, spec.target_path)
  let full_dotfiles_path = filepath.join(home, spec.dotfiles_path)

  case simplifile.is_symlink(full_target_path) {
    Error(err) -> InsufficientPermissions(full_target_path, err) |> Error
    Ok(True) -> FileWasSymlink(full_target_path) |> Error
    Ok(False) -> {
      // make sure the dotfiles path exists
      let _ =
        simplifile.create_directory_all(filepath.directory_name(
          full_target_path,
        ))

      // move the original config(target) to the new dotfiles path
      simplifile.rename(full_target_path, full_dotfiles_path)
      |> result.map_error(FailedToCopy(full_target_path, _))
      |> result.replace(spec)
    }
  }
}

fn to_dotfiles_path(path) {
  string.split(path, on: "/")
  |> list.map(string.replace(_, ".", "dot_"))
  |> string.join("/")
  |> filepath.join(dotfiles, _)
}

// symlink ----------------------------------------------------------------------

/// creates a symlink based on a spec
/// 
/// spec <- the spec
/// home <- `/home/<user>`
///
fn make_symlink_from_spec(spec spec: Spec, home home: String) {
  let Spec(dotfiles_path:, target_path:) = spec

  make_symlink(
    filepath.join(home, dotfiles_path),
    filepath.join(home, target_path),
  )
  |> result.replace(spec)
}

/// creates a symlink from the `dotfiles` dir path to the original path for a given config 
/// Tries to make a backup of existing files at `target_path` by moving them to `target_path`.bak
///
/// `dotfiles_path` <- the path in `~/dotfiles` -- ex: `/home/<user>/dotfiles/dot_config/nvim`
/// `target_path` <- the original path -- ex: `/home/<user>/.config/nvim`
///
fn make_symlink(
  dotfiles_path dotfiles_path: String,
  target_path target_path: String,
) -> Result(String, InternalError) {
  // if the file already exists, and isnt a symlink, make a backup
  let _ = case simplifile.is_symlink(target_path) {
    Ok(False) -> simplifile.rename(target_path, target_path <> ".bak")
    _ -> Ok(Nil)
  }

  shellout.command(
    run: "ln",
    with: [
      // symbolic
      "-s",
      // no-dereference
      "-n",
      // force
      "-f",
      dotfiles_path,
      target_path,
    ],
    in: ".",
    opt: [],
  )
  |> result.map_error(FailedToCreateSymlink)
}

// spec -------------------------------------------------------------------------

type Spec {
  /// both without the /home/<user> for portability
  /// `dotfiles_path` <- the path in `~/dotfiles/dot_config/nvim/` | does start with 'dotfiles'
  /// `target_path` <- the path the config belongs in i.e. `~/.config/nvim`
  ///
  Spec(dotfiles_path: String, target_path: String)
}

fn spec_from_config_path(path: String) -> Result(Spec, InternalError) {
  use path <- result.try(case path {
    "/home" <> _ -> drop_home(path) |> Ok
    "/root/" <> path -> path |> Ok
    _ -> Error(FileNotInHomeDirectory(path))
  })

  Spec(to_dotfiles_path(path), path) |> Ok
}

/// drops '/', 'home' and '<user>' from supplied path
/// uses filepath.join to reassemble the path
///
fn drop_home(from) {
  from
  |> filepath.split()
  // drop `/`, `home` and `<user>`
  |> list.drop(3)
  |> list.fold("", filepath.join)
}

/// gets path of spec.json using `/home/<user>`
///
fn spec_path(home home) {
  home
  |> filepath.join(dotfiles)
  |> filepath.join("spec.json")
}

/// saves provided spec to default spec location
/// spec <- spec to save
/// home <- `/home/<user>/`
///
fn persist_spec(spec: Spec, home: String) -> Result(Nil, InternalError) {
  use specs <- result.try(
    spec_path(home)
    |> load_specs,
  )
  write_specs_to_file([spec, ..specs], home)
}

/// saves provided list of specs to default spec location
/// specs <- list of specs to save
/// home <- `/home/<user>/`
///
fn persist_specs(specs: List(Spec), home: String) -> Result(Nil, InternalError) {
  use old_specs <- result.try(
    spec_path(home)
    |> load_specs,
  )

  list.append(old_specs, specs)
  |> write_specs_to_file(home)
}

/// overwrites the existing spec file with the supplied specs
///
fn write_specs_to_file(specs specs: List(Spec), home home: String) {
  let json_string =
    json.array(list.unique(specs), spec_to_json)
    |> json.to_string()

  simplifile.write(json_string, to: spec_path(home))
  |> result.map_error(FailedToWrite(spec_path(home), _))
}

/// tries to load a list of specs from the given location
///
fn load_specs(from from: String) -> Result(List(Spec), InternalError) {
  let file =
    simplifile.read(from)
    |> result.map_error(FailedToRead(from, _))
  case file {
    // file doesnt exist yet
    Error(FailedToRead(_, simplifile.Enoent)) -> Ok("[]")
    Ok(content) -> Ok(content)
    e -> e
  }
  |> result.try(fn(contents) {
    json.parse(contents, decode.list(spec_decoder()))
    |> result.map_error(FailedToDecode)
  })
}

fn spec_to_json(spec spec: Spec) -> json.Json {
  let Spec(dotfiles_path:, target_path:) = spec
  json.object([
    #("dotfiles_path", json.string(dotfiles_path)),
    #("target_path", json.string(target_path)),
  ])
}

fn spec_decoder() -> decode.Decoder(Spec) {
  use dotfiles_path <- decode.field("dotfiles_path", decode.string)
  use target_path <- decode.field("target_path", decode.string)
  decode.success(Spec(dotfiles_path:, target_path:))
}
