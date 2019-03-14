#!/usr/bin/env python3
import sys, xmltodict, json
print(json.dumps(xmltodict.parse(''.join(sys.stdin.readlines())), ensure_ascii=False))
