#!/usr/bin/env python3

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "data"


class ValidationError(Exception):
    pass


def load_json(path):
    with path.open() as f:
        return json.load(f)


def ensure(condition, message):
    if not condition:
        raise ValidationError(message)


def validate_mapping_file(path, data):
    ensure(isinstance(data, dict), "top-level value must be an object")
    ensure(data, "object must not be empty")
    for group, nutrients in data.items():
        ensure(isinstance(group, str) and group.strip(), "group keys must be non-empty strings")
        ensure(isinstance(nutrients, dict), f"{group}: value must be an object")
        ensure(nutrients, f"{group}: nutrient object must not be empty")
        for nutrient, value in nutrients.items():
            ensure(isinstance(nutrient, str) and nutrient.strip(), f"{group}: nutrient keys must be strings")
            ensure(isinstance(value, (int, float)), f"{group}/{nutrient}: value must be numeric")


def validate_interactions(path, data):
    ensure(isinstance(data, list), "top-level value must be an array")
    for index, item in enumerate(data):
        ensure(isinstance(item, dict), f"item {index}: must be an object")
        ensure(isinstance(item.get("nutrient"), str) and item["nutrient"].strip(), f"item {index}: nutrient missing")
        for field in ("synergistic", "antagonistic", "varies"):
            if field in item:
                ensure(isinstance(item[field], list), f"item {index}: {field} must be an array")
                for value in item[field]:
                    ensure(isinstance(value, str) and value.strip(), f"item {index}: {field} values must be strings")


def validate_normalized_drvs(path, data):
    ensure(isinstance(data, dict), "top-level value must be an object")
    ensure(isinstance(data.get("records"), list), "records must be an array")
    ensure(data.get("source_system") == "EFSA", "source_system must be EFSA")
    for index, record in enumerate(data["records"]):
        ensure(isinstance(record, dict), f"record {index}: must be an object")
        for field in ("category", "nutrient", "target_population", "gender", "source_system", "source_file"):
            ensure(isinstance(record.get(field), str) and record[field].strip(), f"record {index}: {field} missing")
        age = record.get("age")
        ensure(isinstance(age, dict), f"record {index}: age must be an object")
        ensure("raw" in age and "pal" in age, f"record {index}: age is incomplete")
        refs = record.get("references")
        ensure(isinstance(refs, dict), f"record {index}: references must be an object")
        for field in ("AI", "AR", "PRI", "RI", "UL", "safe_and_adequate_intake"):
            ensure(field in refs, f"record {index}: references.{field} missing")
            ref_value = refs[field]
            ensure(ref_value is None or isinstance(ref_value, dict), f"record {index}: references.{field} invalid")


def validate_json_schema(path, data):
    ensure(isinstance(data, dict), "top-level value must be an object")
    ensure(data.get("$schema"), "$schema missing")
    ensure(data.get("type") == "object", "schema root type must be object")
    ensure(isinstance(data.get("$defs"), dict) and data["$defs"], "$defs must be a non-empty object")


def validate_file(path):
    data = load_json(path)
    if path.name in {"DRI_Macros.json", "DRI_Minerals.json", "DRI_Vitamins.json", "EER_Boys.json", "EER_Girls.json", "EER_Men.json", "EER_Women.json"}:
        validate_mapping_file(path, data)
    elif path.name == "interactions.json":
        validate_interactions(path, data)
    elif path.name == "drvs_eu_normalized.json":
        validate_normalized_drvs(path, data)
    elif path.name == "drvs_eu_normalized.schema.json":
        validate_json_schema(path, data)
    else:
        raise ValidationError("no validator defined for file")


def main():
    for path in sorted(DATA_DIR.glob("*.json")):
        try:
            validate_file(path)
            print(f"{path.relative_to(ROOT)}: VALID")
        except Exception as exc:
            print(f"{path.relative_to(ROOT)}: INVALID -> {exc}")


if __name__ == "__main__":
    main()
