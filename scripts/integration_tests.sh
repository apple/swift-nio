#!/bin/bash

mkdir -p .build # for the junit.xml file
./IntegrationTests/run-tests.sh --junit-xml .build/junit-sh-tests.xml
