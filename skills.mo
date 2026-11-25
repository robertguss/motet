## Progressive-disclosure SKILL.md manager (`agentskills.io` compatible).
## Level 1: compact index in stable system prompt.
## Level 2: full SKILL.md body loaded on demand via `skill_read`.
module Skills
expose valid_skill_name?, clamp_description, parse_skill_doc, index_skills, read_skill, save_skill
use Types{MotetError, SkillDoc, SkillSummary}

fn valid_skill_char?(c: Char) : Bool
  c.ascii_letter? or c.ascii_digit? or c == '-' or c == '_'
end

## Enforces the <= 60-char Skill Curator description budget so the stable prompt stays lean.
fn clamp_description(desc: Text) : Text
  promise "skill index descriptions never exceed 60 characters"
    result.char_count <= 60
  end

  examples
    clamp_description("Monitor T3 threads") == "Monitor T3 threads"
    clamp_description(
      "A very long skill description that definitely exceeds the sixty character curator limit"
    ).char_count <=
      60
  end

  clean = desc.trim
  return "Reusable skill" if clean.empty?
  chars = clean.chars
  if chars.size <= 60
    clean
  else
    "#{Text.from_chars(chars.take(57))}..."
  end
end

## Rejects empty names, path traversal, and non-slug characters.
fn valid_skill_name?(name: Text) : Bool
  promise
    (name.contains?("/") or name.contains?("..")) implies not result
    name.empty? implies not result
  end

  examples
    valid_skill_name?("t3-supervisor")
    valid_skill_name?("code_review")
    not valid_skill_name?("../escape")
    not valid_skill_name?("a/b")
    not valid_skill_name?("")
  end

  not name.empty? and name.char_count <= 64 and name.chars.all?(fn(c) valid_skill_char?(c) end)
end

## Parses optional `---` frontmatter (`name`, `description`, `provenance`) from a SKILL.md file.
fn parse_skill_doc(fallback_name: Text, raw: Text) : SkillDoc
  lines = raw.lines
  var name = fallback_name
  var description = "Reusable skill"
  var provenance = "user"
  var body_lines = lines

  if lines.first == Some("---")
    var i = 1
    var closed = false
    while i < lines.size and not closed
      line = lines.get(i) or ""
      if line.trim == "---"
        closed = true
        body_lines = lines.drop(i + 1)
      else
        case line.drop_prefix("name:")
          Some(v): name = v.trim
          None:
            case line.drop_prefix("description:")
              Some(v): description = v.trim
              None:
                case line.drop_prefix("provenance:")
                  Some(v): provenance = v.trim
                  None: Unit
                end
            end
        end
      end
      i += 1
    end
  end

  SkillDoc(
    name: if name.empty?: fallback_name else: name,
    description: description,
    provenance: provenance,
    body: body_lines.join("\n").trim
  )
end

## Level 1 progressive disclosure: compact skill index under `skills/`.
fn index_skills(read_files: ReadFiles) : List(SkillSummary)
  entries = case read_files.entries("skills")
    Ok(items): items
    Error(_): []
  end
  var out = []
  for entry in entries
    case entry.kind
      Folder:
        skill_path = "skills/#{entry.name}/SKILL.md"
        case read_files.read_text(skill_path)
          Ok(raw):
            doc = parse_skill_doc(entry.name, raw)
            out = out.append(
              SkillSummary(
                name: doc.name,
                description: clamp_description(doc.description),
                provenance: doc.provenance,
                path: skill_path,
                usage_count: 0
              )
            )
          Error(_): Unit
        end
      File:
        case entry.name.drop_suffix(".md")
          Some(stem):
            skill_path = "skills/#{entry.name}"
            case read_files.read_text(skill_path)
              Ok(raw):
                doc = parse_skill_doc(stem, raw)
                out = out.append(
                  SkillSummary(
                    name: doc.name,
                    description: clamp_description(doc.description),
                    provenance: doc.provenance,
                    path: skill_path,
                    usage_count: 0
                  )
                )
              Error(_): Unit
            end
          None: Unit
        end
      Link | Other: Unit
    end
  end
  out
end

## Level 2 progressive disclosure: reads a single skill's full Markdown instructions.
fn read_skill(read_files: ReadFiles, name: Text) : Result(SkillDoc, MotetError)
  return Error(BadInput(message: "invalid skill name: #{name}")) if not valid_skill_name?(name)
  dir_path = "skills/#{name}/SKILL.md"
  case read_files.read_text(dir_path)
    Ok(raw): Ok(parse_skill_doc(name, raw))
    Error(_):
      flat_path = "skills/#{name}.md"
      case read_files.read_text(flat_path)
        Ok(raw): Ok(parse_skill_doc(name, raw))
        Error(_): Error(ItemNotFound(message: "skill not found: #{name}"))
      end
  end
end

## Persists a SKILL.md document with explicit write-origin provenance (`user` or `bot_proposed`).
fn save_skill(files: Files, name: Text, description: Text, body: Text, provenance: Text) : Result(
  SkillSummary,
  MotetError
)
  return Error(BadInput(message: "invalid skill name: #{name}")) if not valid_skill_name?(name)
  prov = if provenance.trim.empty?: "user" else: provenance.trim
  desc = clamp_description(description)
  _mk_root = files.make_folder("skills")
  dir = "skills/#{name}"
  _mk_dir = files.make_folder(dir)
  path = "#{dir}/SKILL.md"
  doc_text = [
    "---",
    "name: #{name}",
    "description: #{desc}",
    "provenance: #{prov}",
    "---",
    "",
    body.trim,
    ""
  ].join("\n")
  try files.write_text(path, doc_text).map_error(fn(e) StorageFailed(message: "#{e}") end)
  Ok(SkillSummary(name: name, description: desc, provenance: prov, path: path, usage_count: 0))
end

test "skills index and load SKILL.md with provenance and traversal guards"
  files = Files.in_memory({})
  assert save_skill(files, "t3-supervisor", "Monitor T3 threads", "Check status first.", "user") is
    Ok(summary)
  assert summary.path == "skills/t3-supervisor/SKILL.md"
  listed = index_skills(files.read_only)
  assert listed.size == 1
  assert read_skill(files.read_only, "t3-supervisor") is Ok(doc)
  assert doc.description == "Monitor T3 threads" and doc.body == "Check status first."
  assert read_skill(files.read_only, "../secrets") is Error(BadInput(message: _))
end
