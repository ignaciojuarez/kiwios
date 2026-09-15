#!/usr/bin/ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
FIXTURES = File.join(__dir__, "fixtures")

def executable(path, body)
  File.write(path, "#!/bin/sh\nset -eu\n#{body}\n")
  File.chmod(0o755, path)
end

def write_xcode_app(path)
  FileUtils.mkdir_p(File.join(path, "Contents", "Developer"))
  File.write(File.join(path, "Contents", "Info.plist"), <<~PLIST)
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.apple.dt.Xcode</string></dict></plist>
  PLIST
end

def simctl_devices_json(prefix, count)
  devices = (1..count).map do |index|
    {
      "isAvailable" => true,
      "name" => "#{prefix}-#{index}",
      "state" => "Shutdown",
      "udid" => format("%s-%04d-0000-0000-000000000000", prefix, index)
    }
  end
  { "devices" => { "com.apple.CoreSimulator.SimRuntime.iOS-18-0" => devices } }
end

def run_check(root, bin, name, extra_env = {})
  env = {
    "PATH" => "#{bin}:/usr/bin:/bin", "TEST_ROOT" => root,
    "KIWIOS_XCODES_FIXTURE_ROOT" => root, "KIWIOS_DATA_DIR" => File.join(root, "data")
  }.merge(extra_env)
  stdout, stderr, status = Open3.capture3(env, File.join(ROOT, "xcodes.rb"), name)
  raise "#{name}: unexpected stderr: #{stderr}" unless stderr.empty?
  lines = stdout.lines.map { |line| JSON.parse(line) }
  raise "#{name}: expected one event" unless lines.length == 1
  [lines.first, status]
end

Dir.mktmpdir("kiwios-xcodes-test") do |root|
  bin = File.join(root, "bin")
  app = File.join(root, "Xcode.app")
  FileUtils.mkdir_p(bin)
  write_xcode_app(app)

  executable(File.join(bin, "xcodes"), <<~'SH')
    printf '%s' "$HOME" > "$TEST_ROOT/xcodes-home-seen"
    case "$1" in
      version) exec /bin/cat "$TEST_ROOT/xcodes-version.txt" ;;
      installed) exec /usr/bin/sed "s|__ROOT__|$TEST_ROOT|g" "$TEST_ROOT/xcodes-installed.txt" ;;
      list)
        [ "${TEST_MALFORMED_LIST:-}" = 1 ] && printf 'surprise format\n' && exit 0
        exec /bin/cat "$TEST_ROOT/xcodes-list.txt"
        ;;
      runtimes) exec /bin/cat "$TEST_ROOT/xcodes-runtimes.txt" ;;
      *) exit 2 ;;
    esac
  SH
  executable(File.join(bin, "xcode-select"), 'printf "%s/Xcode.app/Contents/Developer\n" "$TEST_ROOT"')
  executable(File.join(bin, "xcodebuild"), <<~'SH')
    if [ "${1:-}" = "-checkFirstLaunchStatus" ]; then
      [ "${TEST_FIRST_LAUNCH:-}" = "needed" ] && exit 1
      if [ "${TEST_FIRST_LAUNCH:-}" = "missing-flag" ]; then
        printf 'invalid option -checkFirstLaunchStatus\n' >&2
        exit 64
      fi
      exit 0
    fi
    printf 'Xcode 27.0\nBuild version 27A266a\n'
  SH
  executable(File.join(bin, "xcrun"), <<~'SH')
    if [ "$3" = "runtimes" ]; then
      exec /bin/cat "$TEST_ROOT/simctl-runtimes.json"
    fi
    if printf '%s' "${DEVELOPER_DIR:-}" | grep -q 'Xcode-16'; then
      exec /bin/cat "$TEST_ROOT/simctl-devices-16.json"
    fi
    exec /bin/cat "$TEST_ROOT/simctl-devices.json"
  SH
  Dir[File.join(FIXTURES, "*")].each { |fixture| FileUtils.cp(fixture, root) }

  event, status = run_check(root, bin, "tool-health")
  raise "tool-health failed" unless status.success? && event.dig("state", "value") == "Ready"
  seen_home = File.read(File.join(root, "xcodes-home-seen"))
  raise "xcodes HOME was not isolated" unless seen_home == File.join(root, "data", "xcodes-home")

  event, status = run_check(root, bin, "selected-xcode")
  raise "selected-xcode failed" unless status.success? && event.dig("state", "value") == "Xcode 27.0"

  event, status = run_check(root, bin, "installed-xcodes")
  row = event.dig("state", "rows", 0)
  raise "installed-xcodes failed" unless status.success? && row["selected"] == true && row["build"] == "27A266a"

  event, status = run_check(root, bin, "available-xcodes")
  rows = event.dig("state", "rows")
  unlabeled = rows.find { |item| item["version"] == "16.4" }
  installed_only = rows.find { |item| item["version"] == "16.3" }
  selected = rows.find { |item| item["version"] == "27.0" }
  labeled = rows.find { |item| item["version"] == "27.1 Beta" }
  unless status.success? && rows.length == 4 && unlabeled && unlabeled["build"] == "16F6" && unlabeled["architectures"] == "" &&
         installed_only && installed_only["installed"] == true && selected && selected["installed"] == true &&
         selected["architectures"] == "Apple Silicon" && labeled && labeled["channel"] == "Beta" &&
         labeled["architectures"] == "Universal"
    raise "available-xcodes failed"
  end

  event, status = run_check(root, bin, "installed-runtimes")
  rows = event.dig("state", "rows")
  raise "installed-runtimes failed" unless status.success? && rows.length == 2 && rows[1]["available"] == false

  event, status = run_check(root, bin, "simulator-devices")
  rows = event.dig("state", "rows")
  raise "simulator-devices failed" unless status.success? && rows.length == 2 && rows[0]["udid"]

  event, status = run_check(root, bin, "available-runtimes")
  rows = event.dig("state", "rows")
  silicon = rows.find { |item| item["version"] == "18.2" }
  duplicate = rows.find { |item| item["version"] == "18.2 (22C146)" }
  unless status.success? && rows.length == 5 && rows[1]["channel"] == "Beta" && silicon &&
         silicon["architecture"] == "Apple Silicon" && silicon["version"] == "18.2" && duplicate &&
         duplicate["architecture"] == "Apple Silicon"
    raise "available-runtimes failed"
  end

  event, status = run_check(root, bin, "available-xcodes", "KIWIOS_DATA_DIR" => "")
  raise "missing KIWIOS_DATA_DIR did not fail closed" unless !status.success? && event["msg"].include?("KIWIOS_DATA_DIR")

  catalog = (1..101).map { |index| "#{index}.0 (#{index}A)" }
  File.write(File.join(root, "xcodes-list.txt"), "#{catalog.join("\n")}\n")
  event, status = run_check(root, bin, "available-xcodes")
  rows = event.dig("state", "rows")
  unless status.success? && event["t"] == "warn" && event["msg"].include?("showing 100 of 101") &&
         rows.length == 100 && rows.first["version"] == "2.0" && rows.last["version"] == "101.0"
    raise "catalog truncation did not keep the newest 100 rows"
  end

  runtime_catalog = ["-- iOS --"] + (1..101).map { |index| "iOS #{index}.0" }
  File.write(File.join(root, "xcodes-runtimes.txt"), "#{runtime_catalog.join("\n")}\n")
  event, status = run_check(root, bin, "available-runtimes")
  rows = event.dig("state", "rows")
  unless status.success? && event["msg"].include?("showing 100 of 101") && rows.length == 100 &&
         rows.first["version"] == "2.0" && rows.last["version"] == "101.0"
    raise "runtime truncation did not keep the newest 100 rows"
  end

  File.write(File.join(root, "xcodes-list.txt"), "16.4 (16F6) [PowerPC]\n")
  event, status = run_check(root, bin, "available-xcodes")
  raise "unknown catalog leftover did not fail closed" unless !status.success? && event["t"] == "error" && event["msg"].include?("unrecognised row")

  File.write(File.join(root, "xcodes-runtimes.txt"), "-- iOS --\niOS 18.0 [PowerPC]\n")
  event, status = run_check(root, bin, "available-runtimes")
  raise "unknown runtime leftover did not fail closed" unless !status.success? && event["t"] == "error" && event["msg"].include?("unrecognised row")

  event, status = run_check(root, bin, "available-xcodes", "TEST_MALFORMED_LIST" => "1")
  raise "malformed catalog did not fail closed" unless !status.success? && event["t"] == "error" && event["msg"].include?("unrecognised row")

  executable(File.join(bin, "xcode-select"), 'printf "/Library/Developer/CommandLineTools\n"')
  event, status = run_check(root, bin, "selected-xcode")
  unless !status.success? && event["msg"].include?("not a full Xcode") && !event["msg"].include?("outside the disclosed")
    raise "Command Line Tools were not classified as not a full Xcode"
  end

  write_xcode_app(File.join(root, "OtherXcode.app"))
  executable(File.join(bin, "xcode-select"), 'printf "%s/OtherXcode.app/Contents/Developer\n" "$TEST_ROOT"')
  event, status = run_check(root, bin, "selected-xcode", "KIWIOS_XCODES_FIXTURE_ROOT" => "")
  raise "Xcode outside /Applications did not fail closed" unless !status.success? && event["msg"].include?("outside the disclosed /Applications directory")

  executable(File.join(bin, "xcode-select"), 'printf "%s/Xcode.app/Contents/Developer\n" "$TEST_ROOT"')
  event, status = run_check(root, bin, "selected-xcode", "TEST_FIRST_LAUNCH" => "needed")
  unless !status.success? && event["msg"].include?("first-launch")
    raise "pending first launch was not classified before xcodebuild -version"
  end

  event, status = run_check(root, bin, "selected-xcode", "TEST_FIRST_LAUNCH" => "missing-flag")
  raise "missing first-launch flag should fall through to xcodebuild -version" unless status.success? && event.dig("state", "value") == "Xcode 27.0"

  File.write(File.join(root, "simctl-devices.json"), "not-json")
  event, status = run_check(root, bin, "simulator-devices")
  raise "invalid simctl JSON did not fail closed" unless !status.success? && event["msg"].include?("invalid JSON")

  app16 = File.join(root, "Xcode-16.app")
  write_xcode_app(app16)
  File.write(File.join(root, "xcodes-installed.txt"), <<~TXT)
    27.0 (27A266a) [Apple Silicon] (Selected)	#{app}
    16.4 (16F6)	#{app16}
  TXT
  File.write(File.join(root, "simctl-devices.json"), JSON.generate(simctl_devices_json("a", 60)))
  File.write(File.join(root, "simctl-devices-16.json"), JSON.generate(simctl_devices_json("b", 60)))
  event, status = run_check(root, bin, "simulator-devices")
  rows = event.dig("state", "rows")
  names = rows.map { |item| item["name"] }
  unless status.success? && event["msg"].include?("showing 100 of 120") && rows.length == 100 &&
         names.include?("a-1") && names.include?("b-1") && names.include?("a-50") && names.include?("b-50") &&
         !names.include?("a-51") && !names.include?("b-51")
    raise "simulator-devices truncation hid an Xcode"
  end

  executable(File.join(bin, "xcodes"), "[ \"$1\" = version ] && printf '2.2.0\\n' || exit 2")
  event, status = run_check(root, bin, "available-xcodes")
  raise "unsupported version did not fail closed" unless !status.success? && event["t"] == "error" && event["msg"].include?("not been fixture-tested")
end

puts "xcodes plugin fixtures passed"
