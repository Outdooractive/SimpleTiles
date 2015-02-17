#!/bin/bash

puma -e production -b tcp://144.76.95.179:3000 -t 8:32 -w 6 --preload config.ru
