from check_test_results import missing_selections, passed_identifiers


def test_missing_class_is_not_hidden_by_other_passing_tests() -> None:
    passed = {"WhoopTests/WhoopReplicaTests/testSnapshot"}
    assert missing_selections(passed, ["WhoopTests/WhoopPacketPersistenceTests"])
    assert missing_selections(passed, ["WhoopTests", "WhoopTests/WhoopReplicaTests"]) == []
    assert missing_selections(passed, ["WhoopTests/WhoopReplicaTests/testSnap"])  # No prefix match.


def test_identifiers_preserve_bundle_and_require_passing_cases() -> None:
    assert passed_identifiers(
        {
            "testNodes": [
                {
                    "nodeType": "Unit test bundle",
                    "name": "WhoopTests",
                    "children": [
                        {
                            "nodeType": "Test Suite",
                            "children": [
                                {
                                    "nodeType": "Test Case",
                                    "nodeIdentifier": "Suite/testOne()",
                                    "result": "Passed",
                                },
                                {
                                    "nodeType": "Test Case",
                                    "nodeIdentifier": "Suite/testTwo()",
                                    "result": "Skipped",
                                },
                            ],
                        }
                    ],
                }
            ]
        }
    ) == {"WhoopTests/Suite/testOne"}
