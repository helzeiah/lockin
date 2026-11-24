// Tests for PlanParser. Run with ./app/test.sh (compiles this file with the parser, no Xcode needed).
import Foundation

var failures = 0
func expect(_ input: String, _ want: [ParsedTask], line: Int = #line) {
    let got = PlanParser.parse(input)
    if got != want {
        failures += 1
        print("FAIL line \(line): \(input.debugDescription)\n  want \(want)\n  got  \(got)")
    }
}
func t(_ task: String, _ minutes: Int? = nil, _ start: String? = nil) -> ParsedTask { ParsedTask(task: task, minutes: minutes, start: start) }

@main struct PlanParserTests {
    static func main() {
        expect("leetcode 45", [t("leetcode", 45)])
        expect("leetcode 45, co-op web ui 90 at 2pm, essay intro 30", [t("leetcode", 45), t("co-op web ui", 90, "14:00"), t("essay intro", 30)])
        expect("co-op 1.5h at 2pm", [t("co-op", 90, "14:00")])
        expect("essay intro 30m @ 9:15", [t("essay intro", 30, "09:15")])
        expect("gym at 6", [t("gym", nil, "18:00")])
        expect("standup at 9", [t("standup", nil, "09:00")])
        expect("deep work 2 hours from 13:00", [t("deep work", 120, "13:00")])
        expect("read chapter 15", [t("read chapter 15")])
        expect("problem set 4", [t("problem set 4")])
        expect("2 leetcode mediums 45", [t("2 leetcode mediums", 45)])
        expect("study for midterm 1h30", [t("study for midterm", 90)])
        expect("emails 20 min at 4:30pm", [t("emails", 20, "16:30")])
        expect("call with team 3pm", [t("call with team", nil, "15:00")])
        expect("- write intro 25\n- slides 40", [t("write intro", 25), t("slides", 40)])
        expect("  ,  ; ", [])
        expect("plan trip 12", [t("plan trip 12")])
        expect("lunch at 12", [t("lunch", nil, "12:00")])
        expect("night review 11pm 30m", [t("night review", 30, "23:00")])
        expect("fix login bug 45 minutes", [t("fix login bug", 45)])
        expect("marathon session 600", [t("marathon session 600")])
        // Edits without AI
        func cmd(_ input: String, _ want: [PlanCommand], line: Int = #line) {
            let got = PlanParser.commands(input)
            if got != want { failures += 1; print("FAIL line \(line): \(input.debugDescription)\n  want \(want)\n  got  \(got)") }
        }
        cmd("done leetcode", [.done("leetcode")])
        cmd("finished the stats hw", [.done("stats hw")])
        cmd("leetcode done", [.done("leetcode")])
        cmd("remove emails", [.remove("emails")])
        cmd("move essay to 3pm", [.move("essay", start: "15:00")])
        cmd("push essay intro to tomorrow", [.tomorrow("essay intro")])
        cmd("make essay 30 min", [.resize("essay", minutes: 30)])
        cmd("make co-op 1.5h", [.resize("co-op", minutes: 90)])
        cmd("free at 8", [.startFrom("08:00")])
        cmd("i'm free at 7:30pm", [.startFrom("19:30")])
        cmd("done leetcode, gym 60 at 6, push emails to tomorrow", [.done("leetcode"), .add(t("gym", 60, "18:00")), .tomorrow("emails")])
        cmd("do laundry 30", [.add(t("do laundry", 30))])
        cmd("finish essay intro 45", [.add(t("finish essay intro", 45))])

        if failures == 0 { print("PlanParser: all tests passed") } else { print("PlanParser: \(failures) failed"); exit(1) }
    }
}
