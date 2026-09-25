import Foundation

struct ImagePicker {
    let names: [String]

    func next(excluding current: String?, randomIndex: (Int) -> Int) -> String? {
        let choices = names.filter { $0 != current }
        guard !choices.isEmpty else {
            return names.first
        }

        let index = max(0, min(randomIndex(choices.count), choices.count - 1))
        return choices[index]
    }

    func next(excluding current: String?) -> String? {
        next(excluding: current) { Int.random(in: 0..<$0) }
    }
}
