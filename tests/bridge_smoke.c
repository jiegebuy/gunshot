#include <assert.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include "libgotohp.h"
#include "../Jailed/GSRequestRole.h"
int main(void){
 assert(GunshotPing()==1);
 GunshotSetHostBearerProvider(0);
 char *response=GunshotRequest("{\"op\":\"ping\"}","settings");
 assert(strstr(response,"not_initialized")!=0);
 GunshotFree(response);
 char directory[]=".build/bridge-state-XXXXXX";
 assert(mkdtemp(directory)!=NULL);
 char credentials[512];snprintf(credentials,sizeof(credentials),"%s/credentials.json",directory);
 FILE *fixture=fopen(credentials,"w");assert(fixture);
 assert(fputs("{\"account\":{\"credentials\":[\"Email=fixture%40example.com&Token=synthetic\"],\"selected\":\"fixture@example.com\"}}",fixture)>=0);
 assert(fclose(fixture)==0);
 assert(GunshotInitialize(directory)==0);
 // Use the production jailed role selector and real Go authorization/lookup.
 // The previous selector sent this request as settings, rejecting every import
 // before PhotoKit could download an original.
 char *lookup="{\"op\":\"source_lookup\",\"account\":\"fixture@example.com\",\"quality\":\"original\",\"sourceID\":\"fixture-asset/L0/001\"}";
 response=GunshotRequest(lookup,"settings");
 assert(strstr(response,"\"ok\":false")!=NULL);GunshotFree(response);
 response=GunshotRequest(lookup,(char *)GSEmbeddedRequestRole("source_lookup"));
 assert(strstr(response,"\"ok\":true")!=NULL);
 assert(strstr(response,"\"found\":false")!=NULL);GunshotFree(response);
 // Reproduce the Objective-C integer-boxing failure at the actual Go decoder.
 response=GunshotRequest("{\"op\":\"conditions\",\"online\":1,\"wifi\":true,\"charging\":0}","daemon");
 assert(strstr(response,"\"ok\":false")!=NULL);GunshotFree(response);
 response=GunshotRequest("{\"op\":\"conditions\",\"online\":true,\"wifi\":true,\"charging\":false}","daemon");
 assert(strstr(response,"\"ok\":true")!=NULL);GunshotFree(response);
 response=GunshotRequest("{\"op\":\"list\"}","settings");
 assert(strstr(response,"\"online\":true")!=NULL);
 assert(strstr(response,"\"wifi\":true")!=NULL);
 assert(strstr(response,"\"charging\":false")!=NULL);GunshotFree(response);
 // Real C -> Go binary import: preserve bytes across a 1 MiB block and tail,
 // reject replay/oversize, then exercise the normal seal/hash path.
 response=GunshotRequest("{\"op\":\"conditions\",\"online\":false}","daemon");GunshotFree(response);
 response=GunshotRequest("{\"op\":\"begin\",\"account\":\"fixture@example.com\",\"quality\":\"original\",\"resources\":[{\"name\":\"binary.tif\",\"size\":1048713}]}","googlephotos");
 assert(strstr(response,"\"ok\":true"));
 char *idStart=strstr(response,"\"id\":\"");assert(idStart);char id[33];memcpy(id,idStart+6,32);id[32]=0;GunshotFree(response);
 unsigned char *bytes=malloc(1048713);assert(bytes);memset(bytes,255,1048713);
 assert(GunshotAppend(id,0,0,bytes,1048713)==0);
 assert(GunshotAppend(id,0,0,bytes,1048576)==1);
 assert(GunshotAppend(id,0,0,bytes,137)==0);
 assert(GunshotAppend(id,0,1048576,bytes+1048576,137)==1);
 char seal[128];snprintf(seal,sizeof(seal),"{\"op\":\"seal\",\"id\":\"%s\"}",id);
 response=GunshotRequest(seal,"googlephotos");assert(strstr(response,"\"ok\":true"));GunshotFree(response);free(bytes);
 puts("PASS real binary bridge: 1 MiB block, tail, replay rejection and seal");
 puts("PASS real Go bridge rejects numeric conditions and applies JSON booleans");
 puts("PASS jailed source lookup reaches the real core while settings lookup stays denied");
 return 0;
}
