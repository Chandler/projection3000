import Foundation

/// Check the original object's keys before migrations. Codable normally ignores
/// unrecognized fields, which would erase a newer editor's data on the next save.
package enum ProjectCoding {
    package static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        let decoded = try JSONDecoder().decode(type,from:data)
        let original = try JSONSerialization.jsonObject(with:data)
        let known = try JSONSerialization.jsonObject(with:JSONEncoder().encode(decoded))
        try checkFields(original,known:known,path:"$")
        return decoded
    }

    private static func checkFields(_ value: Any, known: Any, path: String) throws {
        if let fields = value as? [String:Any], let model = known as? [String:Any] {
            for (key,item) in fields {
                guard let counterpart = model[key] else {
                    if item is NSNull { continue }
                    throw GraphError("Unsupported field at "+path+"."+key)
                }
                try checkFields(item,known:counterpart,path:path+"."+key)
            }
        } else if let values = value as? [Any], let items = known as? [Any] {
            guard values.count == items.count else { throw GraphError("Unsupported data at "+path) }
            for index in values.indices {
                try checkFields(values[index],known:items[index],path:path+"[\(index)]")
            }
        }
    }
}
