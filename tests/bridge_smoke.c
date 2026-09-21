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
 puts("PASS real Go bridge rejects numeric conditions and applies JSON booleans");
 puts("PASS jailed source lookup reaches the real core while settings lookup stays denied");
 return 0;
}
