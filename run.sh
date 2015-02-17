#!/bin/bash

puma -e production -b tcp://144.76.95.179:3000 -t 8:64 --preload config.ru
