import Foundation

struct StatState {
    let value: String
    let unit: String?
    let detail: String?
    let delta: String?

    init?(_ state: [String: JSONValue]?) {
        guard let state, Set(state.keys).isSubset(of: ["value", "unit", "detail", "delta"]),
              let rawValue = state["value"] else { return nil }
        switch rawValue {
        case .string(let value): self.value = value
        case .number(let value): self.value = String(value)
        default: return nil
        }
        for key in ["unit", "detail", "delta"] {
            if let candidate = state[key], case .string(_) = candidate {} else if state[key] != nil { return nil }
        }
        if case .string(let value)? = state["unit"] { unit = value } else { unit = nil }
        if case .string(let value)? = state["detail"] { detail = value } else { detail = nil }
        if case .string(let value)? = state["delta"] { delta = value } else { delta = nil }
    }
}

enum PluginDataParse<Value> { case success(Value), failure(String) }

struct TableState: Equatable, Sendable {
    struct Column: Identifiable, Equatable, Sendable { let id: String; let label: String }
    struct Row: Identifiable, Equatable, Sendable { let id: String; let values: [String: JSONValue] }
    let columns: [Column]
    let rows: [Row]

    static func parse(_ state: [String: JSONValue]?) -> PluginDataParse<Self> {
        guard let state else { return .failure("The latest result has no state object.") }
        guard Set(state.keys) == ["columns", "rows"],
              case .array(let rawColumns)? = state["columns"],
              case .array(let rawRows)? = state["rows"] else {
            return .failure("State must contain only columns and rows arrays.")
        }
        guard !rawColumns.isEmpty, rawColumns.count <= 12 else {
            return .failure("A table must have 1–12 columns.")
        }
        guard rawRows.count <= 100 else { return .failure("A table can contain at most 100 rows.") }
        var columns: [Column] = [], columnIDs = Set<String>()
        for raw in rawColumns {
            guard case .object(let object) = raw, Set(object.keys) == ["id", "label"],
                  case .string(let id)? = object["id"], id != "id", validID(id), columnIDs.insert(id).inserted,
                  case .string(let label)? = object["label"], !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .failure("Each column needs a unique valid id and nonblank label.") }
            columns.append(Column(id: id, label: label))
        }
        var rows: [Row] = [], rowIDs = Set<String>()
        let allowedKeys = columnIDs.union(["id"])
        for raw in rawRows {
            guard case .object(let object) = raw, Set(object.keys) == allowedKeys,
                  case .string(let id)? = object["id"], validID(id), rowIDs.insert(id).inserted
            else { return .failure("Each row needs a unique valid id and known column keys.") }
            var values: [String: JSONValue] = [:]
            for column in columns {
                guard let value = object[column.id] else { continue }
                switch value {
                case .string, .number, .bool, .null: values[column.id] = value
                case .array, .object: return .failure("Table cells must be scalar values or null.")
                }
            }
            rows.append(Row(id: id, values: values))
        }
        return .success(Self(columns: columns, rows: rows))
    }

    private static func validID(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }
}
