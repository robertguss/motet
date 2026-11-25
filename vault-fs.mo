## Git-backed Personal Markdown Vault & `tobi/qmd` sidecar manager for Motet.
## Stores plain Obsidian-compatible Markdown files under a confined vault folder
## (`daily/`, `notes/`, `projects/`, `finance/`, `pages/`, `templates/`),
## keeps `.qmd/index.yml` path contexts synced, and runs confined Git commits + qmd search.
module VaultFs
expose VaultFileEntry(..),
VaultGitStatus(..),
valid_vault_path?,
default_qmd_index_yml,
init_vault,
list_files,
read_file,
write_file,
git_status,
search_vault
use Command
use Mcp
use Store
use Types{MotetError}

struct VaultFileEntry
  path: Text
  folder: Text
  size_bytes: Int
end

struct VaultGitStatus
  initialized?: Bool
  branch: Text
  dirty_count: Int
  last_commit: Text
  remote: Text
end

## Strict path validator preventing directory traversal, absolute paths, or binary writes.
fn valid_vault_path?(rel_path: Text) : Bool
  promise "vault paths never traverse upward or escape root"
    (rel_path.contains?("..") or rel_path.starts_with?("/")) implies not result
    rel_path.trim.empty? implies not result
  end

  examples
    valid_vault_path?("notes/idea.md")
    valid_vault_path?("daily/2026-11-25.md")
    valid_vault_path?("finance/subscriptions.md")
    not valid_vault_path?("../etc/passwd")
    not valid_vault_path?("/abs/path.md")
    not valid_vault_path?("notes/script.sh")
  end

  p = rel_path.trim
  return false if p.empty? or p.byte_count > 200
  return false if p.starts_with?("/") or
    p.starts_with?("\\") or
    p.contains?("..") or
    p.contains?("\\")
  return false if p.contains?("\n") or p.contains?("\r")
  low = p.ascii_lowercase
  low.ends_with?(".md") or
    low.ends_with?(".txt") or
    low.ends_with?(".yml") or
    low.ends_with?(".yaml")
end

## Declarative `tobi/qmd` index.yml with hierarchical path context annotations for Motet's personal vault.
fn default_qmd_index_yml() : Text
  [
    "collections:",
    "  daily:",
    "    path: daily",
    "    pattern: '**/*.md'",
    "    context:",
    "      '/': 'Daily notes, morning briefs, and day logs'",
    "  notes:",
    "    path: notes",
    "    pattern: '**/*.md'",
    "    context:",
    "      '/': 'Evergreen personal notes and meeting notes'",
    "  projects:",
    "    path: projects",
    "    pattern: '**/*.md'",
    "    context:",
    "      '/': 'Active personal projects and plans'",
    "  finance:",
    "    path: finance",
    "    pattern: '**/*.md'",
    "    context:",
    "      '/': 'Personal receipts, subscriptions, warranties, and Hearth Arvo notes'",
    "  pages:",
    "    path: pages",
    "    pattern: '**/*.md'",
    "    context:",
    "      '/': 'Collaborative long-lived Motet Pages and research reports'",
    ""
  ].join("\n")
end

fn scoped_vault_files(files: Files, vault_root: Text) : Files
  r = vault_root.trim
  if r.empty? or r == ".": files.within("vault") else: files.within(r)
end

fn scoped_vault_read(files: ReadFiles, vault_root: Text) : ReadFiles
  r = vault_root.trim
  if r.empty? or r == ".": files.within("vault") else: files.within(r)
end

vault_folders = ["daily", "notes", "projects", "finance", "pages", "templates"]

## Initializes the Obsidian-compatible Markdown vault folders and `.qmd/index.yml` idempotently.
fn init_vault(files: Files, vault_root: Text) : Result(Unit, MotetError)
  root = if vault_root.trim.empty?: "vault" else: vault_root.trim
  _mk_root = files.make_folder(root)
  ws = scoped_vault_files(files, root)
  for f in vault_folders
    _mk = ws.make_folder(f)
  end
  _mk_qmd = ws.make_folder(".qmd")
  if ws.read_text(".qmd/index.yml") is Error(_)
    try ws.write_text(".qmd/index.yml", default_qmd_index_yml()).map_error(
      fn(e) StorageFailed(message: "vault qmd index write failed: #{e}") end
    )
  end
  Ok(Unit)
end

## Lists all Markdown/text files across the standard personal vault folders.
fn list_files(files: ReadFiles, vault_root: Text) : List(VaultFileEntry)
  ws = scoped_vault_read(files, vault_root)
  var out = []
  for folder in vault_folders
    case ws.entries(folder)
      Ok(items):
        for item in items
          if item.kind == File and valid_vault_path?("#{folder}/#{item.name}")
            rel = "#{folder}/#{item.name}"
            sz = case ws.read_text(rel)
              Ok(txt): txt.byte_count
              Error(_): 0
            end
            out = out.append(VaultFileEntry(path: rel, folder: folder, size_bytes: sz))
          end
        end
      Error(_): Unit
    end
  end
  out
end

## Reads one Markdown file from the personal vault safely.
fn read_file(files: ReadFiles, vault_root: Text, rel_path: Text) : Result(Text, MotetError)
  return Error(BadInput(message: "invalid vault path: #{rel_path}")) if not valid_vault_path?(
    rel_path
  )
  ws = scoped_vault_read(files, vault_root)
  ws.read_text(rel_path.trim).map_error(
    fn(e) ItemNotFound(message: "vault read #{rel_path}: #{e}") end
  )
end

## Writes a Markdown file into the personal vault and best-effort commits to Git.
fn write_file(
  files: Files,
  command: Command,
  vault_root: Text,
  rel_path: Text,
  content: Text,
  commit_message: Text
) : Result(VaultFileEntry, MotetError)
  p = rel_path.trim
  return Error(BadInput(message: "invalid vault path: #{p}")) if not valid_vault_path?(p)
  try init_vault(files, vault_root)
  ws = scoped_vault_files(files, vault_root)
  parts = p.split("/")
  folder = if parts.size > 1: parts.first or "notes" else: ""
  if not folder.empty?
    _mk = ws.make_folder(folder)
  end
  try ws.write_text(p, content).map_error(
    fn(e) StorageFailed(message: "vault write #{p}: #{e}") end
  )

  # Best-effort confined Git auto-commit + qmd index refresh inside the vault directory
  root = if vault_root.trim.empty?: "vault" else: vault_root.trim
  git_cmd = command.within(root).allow_programs(["git"])
  msg = if commit_message.trim.empty?: "motet: update #{p}" else: commit_message.trim
  _add = git_cmd.run("git", ["add", p], 10.seconds)
  _com = git_cmd.run("git", ["commit", "-m", msg], 10.seconds)
  qmd_cmd = command.within(root).allow_programs(["qmd"])
  _qmd = qmd_cmd.run("qmd", ["update"], 15.seconds)

  Ok(VaultFileEntry(path: p, folder: folder, size_bytes: content.byte_count))
end

## Inspects the personal vault's Git backup status without touching any remote network.
fn git_status(command: Command, vault_root: Text, remote: Text) : VaultGitStatus
  root = if vault_root.trim.empty?: "vault" else: vault_root.trim
  git_cmd = command.within(root).allow_programs(["git"])
  branch_res = git_cmd.run("git", ["rev-parse", "--abbrev-ref", "HEAD"], 5.seconds)
  case branch_res
    Ok(br_out) if br_out.ok?:
      st_res = git_cmd.run("git", ["status", "--porcelain"], 5.seconds)
      dirty = case st_res
        Ok(so) if so.ok?: so.stdout.lines.filter(fn(l) not l.trim.empty? end).size
        Ok(_) | Error(_): 0
      end
      log_res = git_cmd.run("git", ["log", "-1", "--oneline"], 5.seconds)
      last_c = case log_res
        Ok(lo) if lo.ok?: lo.stdout.trim
        Ok(_) | Error(_): ""
      end
      VaultGitStatus(
        initialized?: true,
        branch: br_out.stdout.trim,
        dirty_count: dirty,
        last_commit: last_c,
        remote: remote.trim
      )
    Ok(_) | Error(_): VaultGitStatus(
      initialized?: false,
      branch: "",
      dirty_count: 0,
      last_commit: "",
      remote: remote.trim
    )
  end
end

## Hybrid personal vault search: queries `tobi/qmd` sidecar first, falling back to local
## Markdown token search when `qmd` is not running locally.
fn search_vault(
  files: ReadFiles,
  network: Network,
  vault_root: Text,
  query_text: Text,
  qmd_url_opt: Option(Text)
) : Text
  q = query_text.trim
  return "Enter a search query." if q.empty?
  case qmd_url_opt
    Some(url) if not url.trim.empty?:
      case Mcp.qmd_query(network, url, q, None, 8)
        Ok(hit_text): return hit_text
        Error(_): Unit
      end
    Some(_) | None: Unit
  end

  # Local zero-dependency fallback across Markdown vault files
  terms = Store.tokenize(q)
  return "No matches for '#{q}'." if terms.empty?
  ws = scoped_vault_read(files, vault_root)
  entries = list_files(files, vault_root)
  var hits = []
  for entry in entries
    case ws.read_text(entry.path)
      Ok(txt):
        doc_tokens = Store.tokenize("#{entry.path} #{txt}")
        if terms.all?(fn(t) doc_tokens.contains?(t) end)
          snippet = (txt.lines.find(fn(l) not l.trim.empty? end) or "").trim
          hits = hits.append("- **#{entry.path}**\n  #{snippet}")
        end
      Error(_): Unit
    end
  end
  if hits.empty?
    "No local vault matches for '#{q}'."
  else
    hits.take(12).join("\n")
  end
end

test "VaultFs initializes Obsidian+qmd vault, enforces traversal safety, commits to Git, and searches via qmd or local fallback"
  files = Files.in_memory({})
  replies = Command.replies([
    (Command.spec("git", ["add", "notes/coffee.md"]).in_folder("vault"), Command.ok_output("")),
    (
      Command.spec("git", ["commit", "-m", "Add coffee note"]).in_folder("vault"),
      Command.ok_output("[main 1a2b3c4] Add coffee note\n")
    ),
    (
      Command.spec("git", ["rev-parse", "--abbrev-ref", "HEAD"]).in_folder("vault"),
      Command.ok_output("main\n")
    ),
    (Command.spec("git", ["status", "--porcelain"]).in_folder("vault"), Command.ok_output("")),
    (
      Command.spec("git", ["log", "-1", "--oneline"]).in_folder("vault"),
      Command.ok_output("1a2b3c4 Add coffee note\n")
    )
  ])
  cmd = Command.fake(replies)

  assert write_file(
    files,
    cmd,
    "vault",
    "notes/coffee.md",
    "# Espresso\nWarranty valid until 2028.\n",
    "Add coffee note"
  ) is
    Ok(entry)
  assert entry.path == "notes/coffee.md" and entry.folder == "notes"
  assert read_file(files.read_only, "vault", "notes/coffee.md") is Ok(body) and
    body.contains?("Warranty")
  assert read_file(files.read_only, "vault", "../secret.md") is Error(BadInput(message: _))
  assert list_files(files.read_only, "vault").size == 1

  gs = git_status(cmd, "vault", "git@github.com:user/motet-vault.git")
  assert gs.initialized? and gs.branch == "main" and gs.dirty_count == 0

  # Local fallback search works even when qmd sidecar is offline
  res = search_vault(files.read_only, Network.fake({}), "vault", "espresso warranty", None)
  assert res.contains?("notes/coffee.md")
end
