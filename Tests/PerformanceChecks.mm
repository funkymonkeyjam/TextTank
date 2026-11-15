// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic editor load, find, replace and Undo timings with budgets that can fail.
//
//   performance-checks            the gated tier: 1 and 10 MiB, 100 buffers, one long line
//   performance-checks full       the manual tier: the same plus 100 MiB
//
// The budgets are a coarse tripwire, not a benchmark: each is many times the value
// logged on the development Mac (see harness/logs/performance-checks.log), so only a
// change of cost class, such as copying the whole buffer several more times, trips it.
// TEXTTANK_PERF_BUDGET_SCALE multiplies every budget: above 1 for a slow machine, and a
// tiny value proves that the budgets do fail.
#import <AppKit/AppKit.h>
#import "TTEditor.h"
#import "ScintillaView.h"
#include <sys/resource.h>
#include <chrono>
#include <vector>
#import "Checks.h"
static double seconds(){return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();}
static double scale(){const char *value=getenv("TEXTTANK_PERF_BUDGET_SCALE");double parsed=value?atof(value):1;return parsed>0?parsed:1;}
static long peakBytes(){struct rusage usage;getrusage(RUSAGE_SELF,&usage);return usage.ru_maxrss;}
/// Passes when `measured` is within `budget`; a failure prints both.
static void within(double measured,double budget,NSString *what,const char *unit){
 budget*=scale();
 NSString *label=[NSString stringWithFormat:@"%@ stays within its budget",what];
 if(!check(measured<=budget,label.UTF8String)) printf("NOTE %s measured %.6f %s against a budget of %.6f %s\n",what.UTF8String,measured,unit,budget,unit);
}
int main(int argc,char **argv){@autoreleasepool{
 [NSApplication sharedApplication];
 const bool full=argc>1 && strcmp(argv[1],"full")==0;
 std::vector<int> sizes={1,10};if(full)sizes.push_back(100);
 printf("kind,MiB,load_seconds,find_seconds,replace_seconds,undo_seconds,peak_rss_bytes\n");
 for(int mib : sizes){@autoreleasepool{
  NSMutableString *fixture=[NSMutableString stringWithCapacity:mib*1024*1024];
  NSString *line=@"alpha beta gamma delta 0123456789\n";
  while([fixture length]<mib*1024*1024)[fixture appendString:line];
  [fixture appendString:@"UNIQUE-END-TOKEN"];
  TTEditor *editor=[[TTEditor alloc]initWithFrame:NSMakeRect(0,0,900,600)];
  double a=seconds();editor.text=fixture;[editor resetUndoHistory];double b=seconds();
  BOOL found=[editor find:@"UNIQUE-END-TOKEN" matchCase:YES backwards:NO];double c=seconds();
  [editor replaceSelection:@"tail"];double d=seconds();[editor executeCommand:@"undo"];double e=seconds();
  NSString *size=[NSString stringWithFormat:@"%d MiB",mib];
  check(found && [editor.text isEqual:fixture],[[size stringByAppendingString:@" find, replace and Undo restore the exact text"] UTF8String]);
  check(b-a<=60 && c-b<=10,[[size stringByAppendingString:@" load within 60 s and find within 10 s"] UTF8String]);
  long peak=peakBytes();
  printf("multiline,%d,%.6f,%.6f,%.6f,%.6f,%ld\n",mib,b-a,c-b,d-c,e-d,peak);fflush(stdout);
  within(b-a,0.25+0.1*mib,[size stringByAppendingString:@" load"],"s");
  within(c-b,0.25+0.01*mib,[size stringByAppendingString:@" find of the last token"],"s");
  within(d-c,0.1,[size stringByAppendingString:@" replace of one selection"],"s");
  within(e-d,0.1,[size stringByAppendingString:@" Undo of one replacement"],"s");
  // Peak resident size is cumulative for the process, so the ceiling grows with the largest
  // fixture loaded so far: a fixed allowance plus thirty times the fixture's UTF-8 size.
  within((double)peak,150.0*1024*1024+30.0*mib*1024*1024,[size stringByAppendingString:@" peak resident memory"],"bytes");
 }}
 NSMutableArray *tabs=[NSMutableArray array];double start=seconds();
 for(int i=0;i<100;++i){TTEditor *view=[[TTEditor alloc]initWithFrame:NSMakeRect(0,0,900,600)];view.text=@"100 independent synthetic buffers 😀";[tabs addObject:view];}
 double buffers=seconds()-start;
 printf("buffers100,0,%.6f,0,0,0,0\n",buffers);
 check(tabs.count==100 && [[(TTEditor *)tabs.lastObject text] isEqual:@"100 independent synthetic buffers 😀"],"100 independent buffers hold their text");
 within(buffers,1.0,@"creating 100 buffers","s");
 TTEditor *longLine=[[TTEditor alloc]initWithFrame:NSMakeRect(0,0,900,600)];
 NSString *line=[@"a" stringByPaddingToLength:10*1024*1024 withString:@"a" startingAtIndex:0];start=seconds();longLine.text=line;
 double longLoad=seconds()-start;
 check([longLine.text isEqual:line],"10 MiB single line loads exactly");
 printf("longline,10,%.6f,0,0,0,0\n",longLoad);
 within(longLoad,2.0,@"10 MiB single line load","s");
 return ttchecks::finish("PerformanceChecks",full?"full tier to 100 MiB; synthetic editor load/find/replace/Undo; no physical scrolling claim":"gated tier to 10 MiB; synthetic editor load/find/replace/Undo; no physical scrolling claim");
}}
