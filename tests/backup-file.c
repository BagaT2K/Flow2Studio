#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#include "../mac/FlowBackupFile.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
int main(void){
 char directory[]="/tmp/flow2-original-test.XXXXXX";assert(mkdtemp(directory));
 char path[256],partial[256],link[256],missing[256];snprintf(path,sizeof path,"%s/original.bin",directory);snprintf(partial,sizeof partial,"%s/partial.bin",directory);snprintf(link,sizeof link,"%s/link.bin",directory);snprintf(missing,sizeof missing,"%s/absent/file.bin",directory);
 size_t size=262144;uint8_t *image=malloc(size),*copy=malloc(size);assert(image&&copy);for(size_t n=0;n<size;n++)image[n]=(uint8_t)(n*17+9);
 assert(flow_backup_write_once(path,image,size)==1);assert(flow_backup_write_once(path,image,size)==2);
 image[100]^=1;assert(flow_backup_write_once(path,image,size)==0);image[100]^=1;
 FILE *f=fopen(path,"rb");assert(f&&fread(copy,1,size,f)==size&&fgetc(f)==EOF&&!memcmp(image,copy,size));fclose(f);
 f=fopen(partial,"wb");assert(f&&fwrite(image,1,111,f)==111);fclose(f);assert(!flow_backup_write_once(partial,image,size));struct stat st;assert(!stat(partial,&st)&&st.st_size==111);
 assert(!flow_backup_write_once(directory,image,size));assert(!flow_backup_write_once(missing,image,size));
 assert(!symlink(path,link));assert(!flow_backup_write_once(link,image,size));assert(!stat(path,&st)&&st.st_size==(off_t)size);
 assert(!unlink(link)&&!unlink(partial)&&!unlink(path)&&!rmdir(directory));free(image);free(copy);
 puts("Passed: immutable full-size original copy; matching retry; changed/partial file never overwritten; symlink, directory and missing parent rejected.");
}
