package main

import "time"

func unixNowMillis() int64 {
	return time.Now().UnixMilli()
}
