#ifndef FLOW_BACKUP_FILE_H
#define FLOW_BACKUP_FILE_H
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <sys/stat.h>
#include <string.h>
/* Never truncates/replaces an existing original. Existing bytes must match. */
static inline int flow_backup_write_once(const char *path,const uint8_t *bytes,size_t size){
 int flags=O_WRONLY|O_CREAT|O_EXCL;
#ifdef O_NOFOLLOW
 flags|=O_NOFOLLOW;
#endif
 int fd=open(path,flags,0600);
 if(fd<0){
  if(errno!=EEXIST)return 0;
  flags=O_RDONLY;
#ifdef O_NOFOLLOW
  flags|=O_NOFOLLOW;
#endif
  fd=open(path,flags);if(fd<0)return 0;
  struct stat st;int ok=fstat(fd,&st)==0&&S_ISREG(st.st_mode)&&st.st_size==(off_t)size;
  size_t offset=0;uint8_t buffer[4096];
  while(ok&&offset<size){size_t n=size-offset;if(n>sizeof buffer)n=sizeof buffer;ssize_t got=read(fd,buffer,n);if(got<0&&errno==EINTR)continue;if(got<=0||memcmp(buffer,bytes+offset,(size_t)got)){ok=0;break;}offset+=(size_t)got;}
  close(fd);return ok&&offset==size?2:0;
 }
 size_t offset=0;int ok=1;
 while(offset<size){ssize_t n=write(fd,bytes+offset,size-offset);if(n<0&&errno==EINTR)continue;if(n<=0){ok=0;break;}offset+=(size_t)n;}
 if(ok)ok=fsync(fd)==0;
#ifdef F_FULLFSYNC
 if(ok)ok=fcntl(fd,F_FULLFSYNC,0)==0;
#endif
 if(close(fd)!=0)ok=0;
 return ok?1:0;
}
#endif
