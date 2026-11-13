import ApplicationServices
import AppKit

/// Thin, safe wrappers around the Accessibility C API.
enum AX {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) else { return nil }
        if let string = value as? String {
            return string.isEmpty ? nil : string
        }
        if let attributed = value as? NSAttributedString {
            return attributed.string.isEmpty ? nil : attributed.string
        }
        return nil
    }

    static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let value = attribute(element, name), CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as? [AnyObject] ?? []
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(item, to: AXUIElement.self) // Type ID checked above.
        }
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        elements(element, kAXChildrenAttribute)
    }

    static func role(_ element: AXUIElement) -> String? {
        string(element, kAXRoleAttribute)
    }

    static func subrole(_ element: AXUIElement) -> String? {
        string(element, kAXSubroleAttribute)
    }

    static func identifier(_ element: AXUIElement) -> String? {
        string(element, kAXIdentifierAttribute)
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute),
              let sizeValue = attribute(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        // Type IDs checked above.
        let position = unsafeBitCast(positionValue, to: AXValue.self)
        let sizeAX = unsafeBitCast(sizeValue, to: AXValue.self)
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(sizeAX, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let names else { return [] }
        return names as? [String] ?? []
    }
}
