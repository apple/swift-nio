#!/bin/bash

swift build
bin_path=$(swift build --show-bin-path)
