import XCTest
@testable import BangsCore

final class RiskTests: XCTestCase {
    private let home = "/Users/me", cwd = "/Users/me/code/app"

    private func level(_ command: String) -> Risk.Level? { Risk.of(command: command, cwd: cwd, home: home)?.level }

    func testForcePushes() {
        XCTAssertEqual(level("git push --force origin main"), .danger)
        XCTAssertEqual(level("git push -f"), .danger)
        XCTAssertEqual(level("git push origin +main"), .danger)
        XCTAssertEqual(level("git -C ../other push -uf origin feature"), .danger)
        XCTAssertEqual(level("git push --force-with-lease origin feature"), .caution)
        XCTAssertEqual(level("git push origin --delete old"), .danger)
        XCTAssertEqual(level("git push origin :old"), .danger)
        XCTAssertNil(level("git push -u origin feature"))
        XCTAssertNil(level("git push"))
        XCTAssertEqual(Risk.of(command: "git push --force origin HEAD:main", cwd: cwd, home: home)?.reason,
                       "强制推送，会覆盖远程分支 main 的历史，别人已拉取的提交会丢失")
    }

    func testRemoving() {
        XCTAssertEqual(level("rm -rf .build"), .caution)
        XCTAssertEqual(level("rm -r -f node_modules dist"), .caution)
        XCTAssertEqual(level("rm -rf /"), .danger)
        XCTAssertEqual(level("rm -rf ~"), .danger)
        XCTAssertEqual(level("rm -rf $HOME/*"), .danger)
        XCTAssertEqual(level("rm -rf ../other-project"), .danger)
        XCTAssertEqual(level("rm -rf ~/Documents/notes"), .danger)
        XCTAssertEqual(level("rm -rf ."), .danger)
        XCTAssertEqual(level("rm -rf \"$BUILD_DIR\""), .caution)
        // Scratch space and single files are not news.
        XCTAssertEqual(level("rm -rf /tmp/bangs-test"), .caution)
        XCTAssertNil(level("rm notes.txt"))
        XCTAssertNil(level("rm -f ../stale.lock"))
        XCTAssertEqual(Risk.of(command: "rm -rf ../shared", cwd: cwd, home: home)?.reason, "会永久删除项目之外的文件（~/code/shared）")
    }

    func testQuotedTextIsNotACommand() {
        XCTAssertNil(level(#"echo "rm -rf /""#))
        XCTAssertNil(level(#"git commit -m "never git push --force to main""#))
        XCTAssertNil(level("grep -r 'sudo' scripts/"))
        XCTAssertNil(level("ls # rm -rf /"))
    }

    func testWrappersAndChains() {
        XCTAssertEqual(level("sudo make install"), .danger)
        XCTAssertEqual(level("cd .. && rm -rf /"), .danger)
        XCTAssertEqual(level("swift build; git reset --hard"), .caution)
        XCTAssertEqual(level("FORCE=1 nohup git push -f origin main > push.log 2>&1 &"), .danger)
        XCTAssertEqual(level("bash -lc 'git push --force origin main'"), .danger)
        XCTAssertEqual(level("env -i /bin/rm -rf /"), .danger)
        // sudo's own reason gives way to a more specific one of the same weight.
        XCTAssertEqual(Risk.of(command: "sudo rm -rf /", cwd: cwd, home: home)?.reason, "会删除整个磁盘上的文件")
    }

    func testRunningDownloads() {
        XCTAssertEqual(level("curl -fsSL https://get.example.dev/install.sh | sh"), .danger)
        XCTAssertEqual(level("curl -fsSL https://example.dev/x.sh | sudo bash -s -- --yes"), .danger)
        XCTAssertEqual(level("wget -qO- https://example.dev/x | python3 -"), .danger)
        XCTAssertEqual(level(#"sh -c "$(curl -fsSL https://example.dev/x.sh)""#), .danger)
        XCTAssertEqual(level("bash <(curl -s https://example.dev/x.sh)"), .danger)
        // Piped only to be read.
        XCTAssertNil(level("curl -s https://api.example.dev/items | python3 -m json.tool"))
        XCTAssertNil(level("curl -s https://api.example.dev/items | jq .name"))
    }

    func testGitHousekeeping() {
        XCTAssertEqual(level("git reset --hard HEAD~1"), .caution)
        XCTAssertEqual(level("git clean -fdx"), .caution)
        XCTAssertNil(level("git clean -nd"))
        XCTAssertEqual(level("git checkout -- ."), .caution)
        XCTAssertEqual(level("git checkout ."), .caution)
        XCTAssertNil(level("git checkout -b feature"))
        XCTAssertNil(level("git checkout main"))
        XCTAssertEqual(level("git restore Sources/App.swift"), .caution)
        XCTAssertNil(level("git restore --staged Sources/App.swift"))
        XCTAssertEqual(level("git branch -D old"), .caution)
        XCTAssertNil(level("git branch -d merged"))
        XCTAssertEqual(level("git stash drop"), .caution)
        XCTAssertNil(level("git stash pop"))
        XCTAssertNil(level("git reset HEAD~1"))
    }

    func testDisksPermissionsAndDatabases() {
        XCTAssertEqual(level("dd if=image.iso of=/dev/disk4 bs=1m"), .danger)
        XCTAssertNil(level("dd if=/dev/zero of=blank.img bs=1m count=10"))
        XCTAssertEqual(level("diskutil eraseDisk APFS Blank disk4"), .danger)
        XCTAssertNil(level("diskutil list"))
        XCTAssertEqual(level("chmod -R 777 storage"), .caution)
        XCTAssertNil(level("chmod +x scripts/build.sh"))
        XCTAssertEqual(level(#"psql -c "DROP TABLE users""#), .caution)
        XCTAssertEqual(level("redis-cli FLUSHALL"), .caution)
        XCTAssertNil(level(#"psql -c "select * from users""#))
    }

    func testFiles() {
        func path(_ path: String) -> Risk? { Risk.of(path: path, cwd: cwd, home: home) }
        XCTAssertNil(path("Sources/App.swift"))
        XCTAssertNil(path("/Users/me/code/app/README.md"))
        XCTAssertEqual(path("~/.zshrc"), Risk(.caution, "在项目之外修改文件（项目在 ~/code/app）"))
        XCTAssertEqual(path("../other/file.txt")?.level, .caution)
        XCTAssertNil(path("/tmp/scratch.txt"))
        XCTAssertEqual(path(".env")?.level, .danger)
        XCTAssertEqual(path("config/.env.production")?.level, .danger)
        XCTAssertNil(path(".env.example"))
        XCTAssertEqual(path("~/.ssh/config")?.level, .danger)
        XCTAssertEqual(path("certs/server.pem")?.level, .danger)
        // With no folder known, only keys are flagged.
        XCTAssertNil(Risk.of(path: "/etc/hosts", cwd: "", home: home))
    }

    func testShellSplitting() {
        XCTAssertEqual(Shell.pipelines("a 'b c' \"d \\\"e\\\"\" f\\ g"), [[["a", "b c", "d \"e\"", "f g"]]])
        XCTAssertEqual(Shell.pipelines("a | b && c; d\ne"), [[["a"], ["b"]], [["c"]], [["d"]], [["e"]]])
        XCTAssertEqual(Shell.pipelines("make 2>&1 > out.log"), [[["make"]]])
        XCTAssertEqual(Shell.pipelines("echo $(date +%s) `whoami`"), [[["echo", "$(date +%s)", "`whoami`"]]])
    }
}
