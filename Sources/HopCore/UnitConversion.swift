import Foundation

/// "<number> <unit> in|to <unit>", e.g. "5 km in miles", "72f to c",
/// "1.5 gb in mb". Conversion is done by Foundation's Measurement, so both
/// units must measure the same thing (length to length, not length to mass).
enum UnitConversion {
    static func convert(_ input: String) -> Calculator.Answer? {
        let lower = input.lowercased()
        // Split on the last " in " / " to ": "5 in in cm" has an "in" unit too.
        guard let separator = [" in ", " to "]
            .compactMap({ lower.range(of: $0, options: .backwards) })
            .max(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let source = lower[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
        let targetName = lower[separator.upperBound...].trimmingCharacters(in: .whitespaces)

        // "5km" and "5 km" both work: the number is the leading digits.
        let numberPart = source.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "," }
        let sourceName = source.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces)
        guard let amount = Double(numberPart.replacingOccurrences(of: ",", with: "")),
              let from = units[sourceName], let to = units[targetName],
              from.dimension == to.dimension else { return nil }

        let converted = Measurement(value: amount, unit: from.unit).converted(to: to.unit).value
        return Calculator.Answer(
            text: "\(Calculator.format(converted)) \(to.symbol)",
            detail: "\(Calculator.format(amount)) \(from.symbol) in \(to.symbol)")
    }

    private struct Known {
        let unit: Dimension
        let dimension: String
        let symbol: String
    }

    private static let units: [String: Known] = {
        var table: [String: Known] = [:]
        func add(_ unit: Dimension, _ dimension: String, _ symbol: String, _ names: String...) {
            for name in names + [symbol.lowercased()] { table[name] = Known(unit: unit, dimension: dimension, symbol: symbol) }
        }
        // Length
        add(UnitLength.millimeters, "length", "mm", "millimeter", "millimeters")
        add(UnitLength.centimeters, "length", "cm", "centimeter", "centimeters")
        add(UnitLength.meters, "length", "m", "meter", "meters", "metre", "metres")
        add(UnitLength.kilometers, "length", "km", "kilometer", "kilometers", "kms")
        add(UnitLength.inches, "length", "in", "inch", "inches")
        add(UnitLength.feet, "length", "ft", "foot", "feet")
        add(UnitLength.yards, "length", "yd", "yard", "yards")
        add(UnitLength.miles, "length", "mi", "mile", "miles")
        // Mass
        add(UnitMass.grams, "mass", "g", "gram", "grams")
        add(UnitMass.kilograms, "mass", "kg", "kilogram", "kilograms", "kgs")
        // Foundation's pound and ounce are rounded (0.453592 kg); these are the exact definitions.
        add(UnitMass(symbol: "oz", converter: UnitConverterLinear(coefficient: 0.028349523125)), "mass", "oz", "ounce", "ounces")
        add(UnitMass(symbol: "lb", converter: UnitConverterLinear(coefficient: 0.45359237)), "mass", "lb", "lbs", "pound", "pounds")
        // Temperature
        add(UnitTemperature.celsius, "temperature", "°C", "c", "celsius")
        add(UnitTemperature.fahrenheit, "temperature", "°F", "f", "fahrenheit")
        add(UnitTemperature.kelvin, "temperature", "K", "k", "kelvin")
        // Volume
        add(UnitVolume.milliliters, "volume", "mL", "ml", "milliliter", "milliliters")
        add(UnitVolume.liters, "volume", "L", "l", "liter", "liters", "litre", "litres")
        add(UnitVolume.cups, "volume", "cups", "cup")
        add(UnitVolume.fluidOunces, "volume", "fl oz", "floz")
        add(UnitVolume.gallons, "volume", "gal", "gallon", "gallons")
        // Speed
        add(UnitSpeed.milesPerHour, "speed", "mph")
        add(UnitSpeed.kilometersPerHour, "speed", "km/h", "kph", "kmh")
        add(UnitSpeed.metersPerSecond, "speed", "m/s", "mps")
        // Time
        add(UnitDuration.seconds, "time", "s", "sec", "secs", "second", "seconds")
        add(UnitDuration.minutes, "time", "min", "mins", "minute", "minutes")
        add(UnitDuration.hours, "time", "h", "hr", "hrs", "hour", "hours")
        // Data (decimal units, like Finder shows)
        add(UnitInformationStorage.bytes, "data", "B", "byte", "bytes")
        add(UnitInformationStorage.kilobytes, "data", "KB", "kilobyte", "kilobytes")
        add(UnitInformationStorage.megabytes, "data", "MB", "megabyte", "megabytes")
        add(UnitInformationStorage.gigabytes, "data", "GB", "gigabyte", "gigabytes")
        add(UnitInformationStorage.terabytes, "data", "TB", "terabyte", "terabytes")
        return table
    }()
}
