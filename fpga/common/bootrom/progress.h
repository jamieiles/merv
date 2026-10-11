#pragma once

void progress(unsigned long done, unsigned long total);
void progress_ratelimited(unsigned long done, unsigned long total);
void progress_clear();