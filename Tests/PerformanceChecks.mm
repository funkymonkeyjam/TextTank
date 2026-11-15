#import <AppKit/AppKit.h>
#import "TTEditor.h"
#import "ScintillaView.h"
#include <sys/resource.h>
#include <chrono>
#import "Checks.h"
static double seconds(){return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();}
int main(){@autoreleasepool{
 [NSApplication sharedApplication];
 printf("kind,MiB,load_seconds,find_seconds,replace_seconds,undo_seconds,peak_rss_bytes\n");
 for(int mib : {1,10,100}){@autoreleasepool{
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
  struct rusage usage;getrusage(RUSAGE_SELF,&usage);
  printf("multiline,%d,%.6f,%.6f,%.6f,%.6f,%ld\n",mib,b-a,c-b,d-c,e-d,usage.ru_maxrss);fflush(stdout);
 }}
 NSMutableArray *tabs=[NSMutableArray array];double start=seconds();
 for(int i=0;i<100;++i){TTEditor *view=[[TTEditor alloc]initWithFrame:NSMakeRect(0,0,900,600)];view.text=@"100 independent synthetic buffers 😀";[tabs addObject:view];}
 printf("buffers100,0,%.6f,0,0,0,0\n",seconds()-start);
 TTEditor *longLine=[[TTEditor alloc]initWithFrame:NSMakeRect(0,0,900,600)];
 NSString *line=[@"a" stringByPaddingToLength:10*1024*1024 withString:@"a" startingAtIndex:0];start=seconds();longLine.text=line;
 check([longLine.text isEqual:line],"10 MiB single line loads exactly");
 printf("longline,10,%.6f,0,0,0,0\n",seconds()-start);
 return ttchecks::finish("PerformanceChecks","synthetic editor load/find/replace/Undo; no physical scrolling claim");
}}
