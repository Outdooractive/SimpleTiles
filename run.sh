#!/bin/bash

puma -t 8:32 -w 3 --preload config.ru
