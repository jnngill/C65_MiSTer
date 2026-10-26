/* MEGA65 hypervisor DOS for the C65 MiSTer core.
 *
 * Runs in the core's hypervisor mode (rtl/m65_hyp.sv): $8000-$BFFF is this
 * program's RAM, the caller's registers are in the save area at $D640, and
 * memory below $8000 is the caller's (its MAP applies), so file names and
 * directory entries are read and written there with plain pointers.
 *
 * The "SD card" is the image mounted in the core's SD card slot: a FAT32
 * volume (a whole-disk image with an MBR, as on a real MEGA65 card, or a bare
 * FAT32 file system), or, for programs that only ever open one file (Space
 * Commander's SPACE.SCP), any other file, which then answers to every name.
 *
 * Function numbers, register conventions, error codes and the directory
 * entry layout follow src/hyppo/dos.asm of the MEGA65 core (MEGA65/mega65-core).
 * Implemented DOS calls (trap $00, function in A):
 *   $00 getversion  $02 getdefaultdrive  $04 getcurrentdrive  $06 selectdrive
 *   $0C chdir  $12 opendir  $14 readdir  $16 closedir  $18 openfile
 *   $1A readfile  $1C writefile  $1E mkfile  $20 closefile  $22 closeall
 *   $26 rmfile  $2E setname  $30 findfirst  $32 findnext  $34 findfile
 *   $36 loadfile  $38 geterrorcode  $3C cdrootdir  $3E loadfile_attic
 *   $40 d81attach0  $42 d81detach  $44 d81write_en  $46 d81attach1  $4A attach
 * Everything else fails with $82 (not implemented).
 *
 * As in dos.asm, mkfile makes a file of a given size in one contiguous piece
 * (8.3 name, current directory) and writefile overwrites its sectors in turn;
 * files do not grow.  Disk images attach to the F011 when they are D81 sized
 * (819200 bytes) and in one piece; a name without a dot also finds NAME.D81.
 */

#define R(a)    (*(volatile unsigned char *)(a))
#define H_A     R(0xD640)
#define H_X     R(0xD641)
#define H_Y     R(0xD642)
#define H_Z     R(0xD643)
#define H_P     R(0xD647)
#define H_TRAP  R(0xD67E)
#define H_STATE R(0xD674)
#define SDC_CMD R(0xD680)
#define F_IMG   R(0xD68B)
#define SECBUF  ((unsigned char *)0xDE00)

#define E_INVALID_ADDRESS   0x10
#define E_READ_ERROR        0x20
#define E_WRITE_ERROR       0x21
#define E_NO_SUCH_DISK      0x80
#define E_NAME_TOO_LONG     0x81
#define E_NOT_IMPLEMENTED   0x82
#define E_TOO_MANY_OPEN     0x84
#define E_IS_A_DIRECTORY    0x86
#define E_NOT_A_DIRECTORY   0x87
#define E_FILE_NOT_FOUND    0x88
#define E_BAD_FD            0x89
#define E_WRONG_LENGTH      0x8A
#define E_FRAGMENTED        0x8B
#define E_NO_SPACE          0x8C
#define E_FILE_EXISTS       0x8D
#define E_DOUBLE_ATTACH     0x8F
#define E_EOF               0xFF

#define MODE_NONE  0
#define MODE_FAT32 1
#define MODE_RAW   2

#define NFD   4
#define NONE  0xFFFFFFFFUL
#define EOC   0x0FFFFFFFUL
#define D81_SIZE 819200UL

typedef unsigned char u8;
typedef unsigned int u16;
typedef unsigned long u32;

extern u32 far_ptr;
#pragma zpsym("far_ptr")
void __fastcall__ far_put(u16 n);

/* ---- directory entry handed to the program (dos.asm layout, 87 bytes) */
struct dirent {
	char longname[64];
	u8   longlen;
	char shortname[13];
	u32  cluster;
	u32  length;
	u8   attr;
};

/* a place in a directory: cluster, sector within it, entry within the sector */
struct dpos {
	u32 cluster;
	u8  secincl;
	u8  entry;
};

struct fd {
	u8  used, isdir, advance;
	u8  secincl;         /* sector within the cluster */
	u32 cluster;         /* current cluster (raw mode: unused) */
	u32 size, pos;       /* files: length and bytes delivered */
	u32 rawsec;          /* raw mode: next sector */
	u16 entry;           /* directories: entry number within the sector */
};

static u8   mode, err, spc_shift, inited, nfats, fsinfo_done;
static u32  part_start, fat_start, fat_size, data_start, root_cluster, cwd_cluster, max_cluster, fsinfo_sec;
static u32  cached = NONE;
static u32  fat_dirty = NONE;     /* FAT sector (index within the FAT) changed in the buffer */
static struct fd fds[NFD];
static struct dirent de;
static u8   de_valid;
static struct dpos de_pos, lfn_pos;   /* where de's 8.3 entry and its first long name entry are */
static char name[64];
static u8   namelen;
static u8   search_fd = 0xFF;
static char lfn[64];
static u8   lfn_ok, lfn_check;
static u8   wbuf[512];
static u8   fn_a;            /* the caller's A: left as it was by calls that succeed */

/* ---------------------------------------------------------------- results */
static void ok(void)      { H_P |= 0x01; }
static void fail(u8 code) { err = code; H_A = code; H_P &= 0xFE; }

/* ---------------------------------------------------------------- sectors */
static u8 sd_cmd(u32 sec, u8 cmd)
{
	R(0xD681) = (u8)sec;
	R(0xD682) = (u8)(sec >> 8);
	R(0xD683) = (u8)(sec >> 16);
	R(0xD684) = (u8)(sec >> 24);
	SDC_CMD = cmd;
	while (SDC_CMD & 0x03) ;
	if (SDC_CMD & 0x60) { cached = NONE; return 0; }
	cached = sec;
	return 1;
}

static u8 sd_write(u32 sec) { return sd_cmd(sec, 0x03); }

/* write a changed FAT sector back, to every FAT */
static u8 fat_flush(void)
{
	u8 k;
	u32 s;
	if (fat_dirty == NONE) return 1;
	s = fat_dirty;
	fat_dirty = NONE;
	for (k = 0; k < nfats; k++) {
		/* the buffer still holds the sector after each write */
		if (!sd_write(fat_start + k * fat_size + s)) return 0;
	}
	return 1;
}

static u8 sd_read(u32 sec)
{
	if (sec == cached) return 1;
	if (fat_dirty != NONE && !fat_flush()) return 0;
	if (sec == cached) return 1;
	return sd_cmd(sec, 0x02);
}

static u16 get16(u16 o) { return SECBUF[o] | ((u16)SECBUF[o + 1] << 8); }
static u32 get32(u16 o) { return get16(o) | ((u32)get16(o + 2) << 16); }
static void put32(u16 o, u32 v)
{
	SECBUF[o] = (u8)v; SECBUF[o + 1] = (u8)(v >> 8); SECBUF[o + 2] = (u8)(v >> 16); SECBUF[o + 3] = (u8)(v >> 24);
}

static u32 clus_sector(u32 c) { return data_start + ((c - 2) << spc_shift); }

/* bring FAT sector idx (within the first FAT) into the buffer */
static u8 fat_load(u32 idx)
{
	if (fat_dirty == idx && cached != NONE) return 1;
	if (fat_dirty != NONE && !fat_flush()) return 0;
	return sd_read(fat_start + idx);
}

static u32 next_cluster(u32 c)
{
	if (!fat_load(c >> 7)) return EOC;
	return get32((u16)(c & 127) << 2) & 0x0FFFFFFFUL;
}

static u8 fat_set(u32 c, u32 v)
{
	u16 o;
	if (!fat_load(c >> 7)) return 0;
	o = (u16)(c & 127) << 2;
	put32(o, (v & 0x0FFFFFFFUL) | ((u32)(SECBUF[o + 3] & 0xF0) << 24));
	fat_dirty = c >> 7;
	return 1;
}

static u8 is_eoc(u32 c) { return c < 2 || c >= 0x0FFFFFF8UL; }

static u8 writable(void)
{
	if (mode == MODE_NONE) { fail(E_NO_SUCH_DISK); return 0; }
	if (H_STATE & 0x02) { fail(E_WRITE_ERROR); return 0; }
	return 1;
}

/* the free cluster count in FSINFO is no longer right once we allocate: mark it unknown */
static void fsinfo_invalidate(void)
{
	u8 i;
	if (fsinfo_done || fsinfo_sec == 0) return;
	fsinfo_done = 1;
	if (!sd_read(fsinfo_sec) || get32(0) != 0x41615252UL) return;
	for (i = 0; i < 8; i++) SECBUF[488 + i] = 0xFF;
	sd_write(fsinfo_sec);
}

/* ---------------------------------------------------------------- volume */
static u8 try_bpb(u32 sec)
{
	u8 spc, i;
	u32 total;
	if (!sd_read(sec) || SECBUF[510] != 0x55 || SECBUF[511] != 0xAA) return 0;
	if (get16(11) != 512 || get16(22) != 0) return 0;      /* 512 byte sectors, FAT32 (no FAT16 size) */
	spc = SECBUF[13];
	if (spc == 0 || SECBUF[16] == 0) return 0;
	for (spc_shift = 0, i = spc; i > 1; i >>= 1) spc_shift++;
	nfats        = SECBUF[16];
	fat_size     = get32(36);
	part_start   = sec;
	fat_start    = sec + get16(14);
	data_start   = fat_start + nfats * fat_size;
	root_cluster = get32(44);
	fsinfo_sec   = get16(48) ? sec + get16(48) : 0;
	total        = get16(19) ? get16(19) : get32(32);
	max_cluster  = ((total - (data_start - sec)) >> spc_shift) + 1;
	if (max_cluster > (fat_size << 7) - 1) max_cluster = (fat_size << 7) - 1;
	return 1;
}

static void fs_init(void)
{
	u8 i;
	u16 o;
	mode = MODE_NONE;
	cached = NONE;
	fat_dirty = NONE;
	fsinfo_done = 0;
	de_valid = 0;
	for (i = 0; i < NFD; i++) fds[i].used = 0;
	search_fd = 0xFF;
	if (!(H_STATE & 0x01)) return;
	if (try_bpb(0)) mode = MODE_FAT32;
	else if (sd_read(0) && SECBUF[510] == 0x55 && SECBUF[511] == 0xAA) {
		/* MBR: the first FAT32 partition (a MEGA65 card also has its system partition) */
		for (i = 0; i < 4 && mode == MODE_NONE; i++) {
			o = 0x1BE + i * 16;
			if (SECBUF[o + 4] == 0x0B || SECBUF[o + 4] == 0x0C) {
				if (try_bpb(get32(o + 8))) mode = MODE_FAT32;
				else sd_read(0);
			}
		}
	}
	if (mode == MODE_NONE) mode = MODE_RAW;
	cwd_cluster = root_cluster;
}

/* ---------------------------------------------------------------- names */
static char upc(char c) { return (c >= 'a' && c <= 'z') ? c - 32 : c; }

/* case-insensitive match of the requested name against s, with * and ? */
static u8 match(const char *p, const char *s)
{
	while (*p) {
		if (*p == '*') {
			p++;
			if (!*p) return 1;
			for (; *s; s++) if (match(p, s)) return 1;
			return 0;
		}
		if (!*s) return 0;
		if (*p != '?' && upc(*p) != upc(*s)) return 0;
		p++; s++;
	}
	return *s == 0;
}

/* ---------------------------------------------------------------- directories */
static u8 alloc_fd(void)
{
	u8 i;
	for (i = 0; i < NFD; i++) if (!fds[i].used) { fds[i].used = 1; fds[i].advance = 0; return i; }
	return 0xFF;
}

static void open_dir(struct fd *f, u32 cluster)
{
	f->isdir = 1; f->cluster = cluster; f->secincl = 0; f->entry = 0; f->pos = 0;
}

static u8 lfn_sum(const u8 *e)
{
	u8 s = 0, i;
	for (i = 0; i < 11; i++) s = ((s & 1) ? 0x80 : 0) + (s >> 1) + e[i];
	return s;
}

/* step a directory position to the next entry; 0 at the end of the cluster chain */
static u8 dpos_step(struct dpos *p)
{
	if (++p->entry == 16) {
		p->entry = 0;
		if (++p->secincl == (1 << spc_shift)) {
			p->secincl = 0;
			p->cluster = next_cluster(p->cluster);
			if (is_eoc(p->cluster)) return 0;
		}
	}
	return 1;
}

/* the entry at p, read into the buffer; returns its offset in the buffer */
static u8 *dpos_entry(struct dpos *p)
{
	if (is_eoc(p->cluster) || !sd_read(clus_sector(p->cluster) + p->secincl)) return 0;
	return SECBUF + ((u16)p->entry << 5);
}

/* next directory entry into de; 0 at the end of the directory */
static u8 read_dirent(struct fd *f)
{
	u8 *e, i, j, k, seq;
	u16 o;
	struct dpos p;
	if (mode == MODE_RAW) {
		if (f->pos) return 0;
		f->pos = 1;
		for (i = 0; i < 64; i++) de.longname[i] = 0;
		de.longname[0] = 'D'; de.longname[1] = 'A'; de.longname[2] = 'T'; de.longname[3] = 'A';
		de.longlen = 4;
		for (i = 0; i < 13; i++) de.shortname[i] = de.longname[i];
		de.cluster = 0; de.length = ((u32)R(0xD673) << 24) | ((u32)R(0xD672) << 16) | ((u16)R(0xD671) << 8) | R(0xD670);
		de.attr = 0x20;
		de_valid = 1;
		return 1;
	}
	lfn_ok = 0;
	for (;;) {
		/* the fd's place: entry f->entry of sector f->secincl of cluster f->cluster */
		if (f->entry == 16) {
			p.cluster = f->cluster; p.secincl = f->secincl; p.entry = 15;
			if (!dpos_step(&p)) { f->cluster = EOC; return 0; }
			f->cluster = p.cluster; f->secincl = p.secincl; f->entry = 0;
		}
		p.cluster = f->cluster; p.secincl = f->secincl; p.entry = (u8)f->entry;
		e = dpos_entry(&p);
		if (!e) return 0;
		o = (u16)f->entry << 5;
		f->entry++;
		if (e[0] == 0x00) { f->entry--; return 0; }          /* end of directory (stay there) */
		if (e[0] == 0xE5) { lfn_ok = 0; continue; }
		if (e[11] == 0x0F) {
			/* long file name piece: 13 UTF-16 characters, last piece first */
			seq = e[0] & 0x3F;
			if (e[0] & 0x40) { for (i = 0; i < 64; i++) lfn[i] = 0; lfn_ok = 1; lfn_check = e[13]; lfn_pos = p; }
			if (!lfn_ok || seq == 0 || seq > 4 || e[13] != lfn_check) { lfn_ok = 0; continue; }
			k = (seq - 1) * 13;
			for (j = 0; j < 13; j++) {
				static const u8 pos[13] = { 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
				o = pos[j];
				if (e[o] == 0 && e[o + 1] == 0) break;
				if (k + j < 63) lfn[k + j] = (e[o + 1] || e[o] >= 0x80) ? '?' : e[o];
			}
			continue;
		}
		if (e[11] & 0x08) { lfn_ok = 0; continue; }          /* volume label */
		/* 8.3 name */
		o = (u16)p.entry << 5;
		k = 0;
		for (i = 0; i < 8 && e[i] != ' '; i++) de.shortname[k++] = e[i];
		if (e[8] != ' ') {
			de.shortname[k++] = '.';
			for (i = 8; i < 11 && e[i] != ' '; i++) de.shortname[k++] = e[i];
		}
		de.shortname[k] = 0;
		for (i = 0; i < 64; i++) de.longname[i] = 0;
		if (lfn_ok && lfn_check == lfn_sum(e)) {
			for (i = 0; i < 63 && lfn[i]; i++) de.longname[i] = lfn[i];
		} else {
			for (i = 0; i <= k; i++) de.longname[i] = de.shortname[i];
			i = k;
			lfn_pos = p;
		}
		de.longlen = i;
		de.cluster = ((u32)get16(o + 20) << 16) | get16(o + 26);
		de.length  = get32(o + 28);
		de.attr    = e[11];
		de_pos     = p;
		de_valid   = 1;
		return 1;
	}
}

/* find the requested name in the current directory, leaving it in de */
static u8 find_next(u8 fdn)
{
	struct fd *f = &fds[fdn];
	if (mode == MODE_RAW) return read_dirent(f);
	while (read_dirent(f)) {
		if (de.shortname[0] == '.' ) {
			/* "." and ".." only match exactly */
			if (match(name, de.shortname)) return 1;
			continue;
		}
		if (match(name, de.longname) || match(name, de.shortname)) return 1;
	}
	return 0;
}

static u8 find_first(void)
{
	u8 n;
	if (mode == MODE_NONE) { fail(E_NO_SUCH_DISK); return 0xFF; }
	if (search_fd != 0xFF) { fds[search_fd].used = 0; search_fd = 0xFF; }
	n = alloc_fd();
	if (n == 0xFF) { fail(E_TOO_MANY_OPEN); return 0xFF; }
	open_dir(&fds[n], cwd_cluster);
	de_valid = 0;
	if (!find_next(n)) { fds[n].used = 0; de_valid = 0; fail(E_FILE_NOT_FOUND); return 0xFF; }
	search_fd = n;
	return n;
}

static void close_search(void)
{
	if (search_fd != 0xFF) { fds[search_fd].used = 0; search_fd = 0xFF; }
}

/* find the requested name, closing the search again */
static u8 find_file(void)
{
	if (find_first() == 0xFF) return 0;
	close_search();
	return 1;
}

/* a free run of n clusters; 0 if the card has none */
static u32 find_free_run(u32 n)
{
	u32 c, start = 0, run = 0, s, nsec;
	u16 o;
	nsec = (max_cluster >> 7) + 1;
	for (s = 0; s < nsec; s++) {
		if (!fat_load(s)) return 0;
		c = s << 7;
		for (o = 0; o < 512; o += 4, c++) {
			if (c < 2 || c > max_cluster) continue;
			if ((SECBUF[o] | SECBUF[o + 1] | SECBUF[o + 2] | (SECBUF[o + 3] & 0x0F)) == 0) {
				if (!run) start = c;
				if (++run == n) return start;
			}
			else run = 0;
		}
	}
	return 0;
}

/* claim n clusters from start as one chain */
static u8 claim_chain(u32 start, u32 n)
{
	u32 c;
	for (c = start; c < start + n - 1; c++) if (!fat_set(c, c + 1)) return 0;
	if (!fat_set(start + n - 1, EOC)) return 0;
	return fat_flush();
}

/* zero all sectors of cluster c */
static u8 zero_cluster(u32 c)
{
	u16 i;
	u8 s;
	if (!fat_flush()) return 0;
	for (s = 0; s < (1 << spc_shift); s++) {
		for (i = 0; i < 512; i++) SECBUF[i] = 0;
		cached = NONE;
		if (!sd_write(clus_sector(c) + s)) return 0;
	}
	return 1;
}

/* a free entry in the current directory (growing it by a cluster if it is full) */
static u8 free_dirent(struct dpos *p)
{
	u8 *e;
	u32 last, c;
	p->cluster = cwd_cluster; p->secincl = 0; p->entry = 0;
	for (;;) {
		e = dpos_entry(p);
		if (!e) return 0;
		if (e[0] == 0x00 || e[0] == 0xE5) return 1;
		last = p->cluster;
		if (!dpos_step(p)) break;
	}
	/* full: add a cluster to the directory */
	c = find_free_run(1);
	if (!c) { fail(E_NO_SPACE); return 0; }
	if (!fat_set(last, c) || !claim_chain(c, 1) || !zero_cluster(c)) { fail(E_WRITE_ERROR); return 0; }
	p->cluster = c; p->secincl = 0; p->entry = 0;
	return 1;
}

/* ---------------------------------------------------------------- files */
static u8 open_current(void)
{
	u8 n;
	struct fd *f;
	if (!de_valid) { fail(E_FILE_NOT_FOUND); return 0xFF; }
	if (mode != MODE_RAW && (de.attr & 0x10)) { fail(E_IS_A_DIRECTORY); return 0xFF; }
	n = alloc_fd();
	if (n == 0xFF) { fail(E_TOO_MANY_OPEN); return 0xFF; }
	f = &fds[n];
	f->isdir = 0; f->cluster = de.cluster; f->secincl = 0; f->size = de.length; f->pos = 0; f->rawsec = 0;
	return n;
}

/* the file's next sector number; 0xFFFFFFFF at its end */
static u32 file_sector(struct fd *f)
{
	if (f->pos >= f->size) return NONE;
	if (mode == MODE_RAW) return f->rawsec;
	if (f->advance) {
		f->advance = 0;
		if (++f->secincl == (1 << spc_shift)) {
			f->secincl = 0;
			f->cluster = next_cluster(f->cluster);
		}
	}
	if (is_eoc(f->cluster)) return NONE;
	return clus_sector(f->cluster) + f->secincl;
}

/* bytes of the current sector that belong to the file; moves the file on */
static u16 file_done(struct fd *f)
{
	u32 left = f->size - f->pos;
	u16 n = left > 512 ? 512 : (u16)left;
	f->pos += n;
	f->rawsec++;
	f->advance = 1;
	return n;
}

/* read the file's next sector into the sector buffer; returns its byte count (0 = end) */
static u16 read_sector(struct fd *f)
{
	u32 sec = file_sector(f);
	if (sec == NONE) return 0;
	cached = NONE;              /* the program may have changed the buffer */
	if (!sd_read(sec)) { fail(E_READ_ERROR); return 0xFFFF; }
	return file_done(f);
}

/* write the sector buffer to the file's next sector */
static u16 write_sector(struct fd *f)
{
	u32 sec;
	u16 i;
	for (i = 0; i < 512; i++) wbuf[i] = SECBUF[i];      /* finding the sector may read the FAT */
	sec = file_sector(f);
	if (sec == NONE) return 0;
	if (!fat_flush()) { fail(E_WRITE_ERROR); return 0xFFFF; }
	for (i = 0; i < 512; i++) SECBUF[i] = wbuf[i];
	cached = NONE;
	if (!sd_write(sec)) { fail(E_WRITE_ERROR); return 0xFFFF; }
	return file_done(f);
}

static struct fd *get_fd(u8 n)
{
	if (n >= NFD || !fds[n].used) { fail(E_BAD_FD); return 0; }
	return &fds[n];
}

/* X = file descriptor; programs written for the single file DOS may leave X
   at anything, so fall back to the one open file */
static struct fd *file_fd(void)
{
	struct fd *f;
	u8 n;
	f = (H_X < NFD && fds[H_X].used && !fds[H_X].isdir) ? &fds[H_X] : 0;
	for (n = 0; !f && n < NFD; n++) if (fds[n].used && !fds[n].isdir) f = &fds[n];
	if (!f) fail(E_BAD_FD);
	return f;
}

/* ---------------------------------------------------------------- calls */
static void do_setname(void)
{
	const char *p;
	u8 i;
	if (H_Y >= 0x7F) { fail(E_INVALID_ADDRESS); return; }
	p = (const char *)((u16)H_Y << 8);
	for (i = 0; i < 63 && p[i]; i++) name[i] = p[i];
	if (p[i] && i == 63) { namelen = 0; name[0] = 0; fail(E_NAME_TOO_LONG); return; }
	name[i] = 0;
	namelen = i;
	ok();
}

static void do_loadfile(u8 mb)
{
	u8 n;
	u16 got;
	u32 dest;
	struct fd *f;
	if (!find_file()) return;
	n = open_current();
	if (n == 0xFF) return;
	f = &fds[n];
	dest = ((u32)mb << 24) | ((u32)H_Z << 16) | ((u16)H_Y << 8) | H_X;
	for (;;) {
		got = read_sector(f);
		if (got == 0xFFFF) { f->used = 0; return; }
		if (got == 0) break;
		far_ptr = dest;
		far_put(got);
		dest += got;
	}
	f->used = 0;
	ok();
}

static void do_mkfile(void)
{
	u32 size, n, start;
	struct dpos p;
	u8 *e, i, j, dot;
	char c;
	if (!writable()) return;
	if (mode != MODE_FAT32) { fail(E_NOT_IMPLEMENTED); return; }
	if (namelen == 0) { fail(E_FILE_NOT_FOUND); return; }
	if (find_file()) { fail(E_FILE_EXISTS); return; }
	H_A = fn_a;                 /* not finding it was the good outcome */
	size = ((u32)H_Z << 16) | ((u16)H_Y << 8) | H_X;
	n = (size + (512UL << spc_shift) - 1) >> (9 + spc_shift);
	if (n == 0) n = 1;
	start = find_free_run(n);
	if (!start) { fail(E_NO_SPACE); return; }
	fsinfo_invalidate();
	if (!claim_chain(start, n)) { fail(E_WRITE_ERROR); return; }
	if (!free_dirent(&p)) return;
	e = dpos_entry(&p);
	if (!e) { fail(E_READ_ERROR); return; }
	for (i = 0; i < 32; i++) e[i] = 0;
	for (i = 0; i < 11; i++) e[i] = ' ';
	/* 8.3 name: up to 8 characters before the last dot, 3 after */
	for (dot = 0xFF, i = 0; i < namelen; i++) if (name[i] == '.') dot = i;
	for (i = 0, j = 0; i < namelen && i != dot && j < 8; i++) {
		c = upc(name[i]);
		e[j++] = (c <= ' ' || c == '"' || c == '*' || c == '?' || c == '/' || c == ':') ? '_' : c;
	}
	if (dot != 0xFF)
		for (i = dot + 1, j = 8; i < namelen && j < 11; i++) e[j++] = upc(name[i]);
	e[11] = 0x20;
	e[20] = (u8)(start >> 16); e[21] = (u8)(start >> 24);
	e[26] = (u8)start;         e[27] = (u8)(start >> 8);
	put32((u16)p.entry << 5 | 28, size);
	if (!sd_write(clus_sector(p.cluster) + p.secincl)) { fail(E_WRITE_ERROR); return; }
	/* the new file is the current one, so openfile can follow */
	if (!find_file()) return;
	ok();
}

static void do_rmfile(void)
{
	u8 *e;
	u32 c, nx;
	struct dpos p;
	if (!writable()) return;
	if (mode != MODE_FAT32 || !de_valid) { fail(E_FILE_NOT_FOUND); return; }
	if (de.attr & 0x10) { fail(E_IS_A_DIRECTORY); return; }
	/* mark the long name entries and the 8.3 entry deleted */
	p = lfn_pos;
	for (;;) {
		e = dpos_entry(&p);
		if (!e) { fail(E_READ_ERROR); return; }
		e[0] = 0xE5;
		if (!sd_write(clus_sector(p.cluster) + p.secincl)) { fail(E_WRITE_ERROR); return; }
		if (p.cluster == de_pos.cluster && p.secincl == de_pos.secincl && p.entry == de_pos.entry) break;
		if (!dpos_step(&p)) break;
	}
	/* free its clusters */
	fsinfo_invalidate();
	for (c = de.cluster; !is_eoc(c); c = nx) {
		nx = next_cluster(c);
		if (!fat_set(c, 0)) { fail(E_WRITE_ERROR); return; }
	}
	if (!fat_flush()) { fail(E_WRITE_ERROR); return; }
	de_valid = 0;
	ok();
}

/* attach the requested D81 to drive d (0 / 1) */
static void do_attach(u8 d)
{
	u32 c, n;
	u8 r;
	if (namelen == 0) { fail(E_FILE_NOT_FOUND); return; }
	if (!find_file()) {
		/* MOUNT "NAME" finds NAME.D81 too */
		for (r = 0; r < namelen && name[r] != '.'; r++) ;
		if (r < namelen || namelen > 59) return;
		name[namelen] = '.'; name[namelen + 1] = 'D'; name[namelen + 2] = '8'; name[namelen + 3] = '1'; name[namelen + 4] = 0;
		r = find_file();
		name[namelen] = 0;
		if (!r) return;
		H_A = fn_a;
	}
	if (mode != MODE_FAT32) { fail(E_NOT_IMPLEMENTED); return; }
	if (de.attr & 0x10) { fail(E_IS_A_DIRECTORY); return; }
	if (de.length != D81_SIZE) { fail(E_WRONG_LENGTH); return; }
	/* the image must be in one piece: the F011 reads it by sector number */
	c = de.cluster;
	for (n = ((D81_SIZE / 512) >> spc_shift) - 1; n; n--) {
		if (next_cluster(c) != c + 1) { fail(E_FRAGMENTED); return; }
		c++;
	}
	c = clus_sector(de.cluster);
	/* the same image on both drives would be written from two places */
	if ((F_IMG & (d ? 0x01 : 0x08)) &&
	    R(d ? 0xD68C : 0xD690) == (u8)c && R(d ? 0xD68D : 0xD691) == (u8)(c >> 8) &&
	    R(d ? 0xD68E : 0xD692) == (u8)(c >> 16) && R(d ? 0xD68F : 0xD693) == (u8)(c >> 24)) {
		fail(E_DOUBLE_ATTACH); return;
	}
	r = d ? 0x90 : 0x8C;
	R(0xD600 + r) = (u8)c; R(0xD601 + r) = (u8)(c >> 8); R(0xD602 + r) = (u8)(c >> 16); R(0xD603 + r) = (u8)(c >> 24);
	r = (H_STATE & 0x02) ? 0x03 : 0x07;           /* read only SD card: not write enabled */
	if (d) F_IMG = (F_IMG & 0xC7) | (r << 3);
	else   F_IMG = (F_IMG & 0xF8) | r;
	ok();
}

static void dos(u8 fn)
{
	u8 n, i;
	struct fd *f;
	u16 got;
	u8 *d;
	switch (fn) {
	case 0x00: H_A = 0x01; H_X = 0x03; H_Y = 0x01; H_Z = 0x03; ok(); break;    /* getversion */
	case 0x02: case 0x04: H_A = 0; ok(); break;                                 /* default / current drive */
	case 0x06: if (H_X == 0) ok(); else fail(E_NO_SUCH_DISK); break;            /* selectdrive */
	case 0x0C:                                                                  /* chdir (current dirent) */
		if (mode != MODE_FAT32 || !de_valid || !(de.attr & 0x10)) { fail(E_NOT_A_DIRECTORY); break; }
		cwd_cluster = de.cluster ? de.cluster : root_cluster;
		H_A = 0; ok(); break;
	case 0x12:                                                                  /* opendir */
		if (mode == MODE_NONE) { fail(E_NO_SUCH_DISK); break; }
		n = alloc_fd();
		if (n == 0xFF) { fail(E_TOO_MANY_OPEN); break; }
		open_dir(&fds[n], cwd_cluster);
		H_A = n; ok(); break;
	case 0x14:                                                                  /* readdir X = fd, Y = page */
		f = get_fd(H_X);
		if (!f) break;
		if (H_Y >= 0x7F) { fail(E_INVALID_ADDRESS); break; }
		if (!read_dirent(f)) { fail(E_EOF); break; }
		d = (u8 *)((u16)H_Y << 8);
		for (i = 0; i < sizeof(de); i++) d[i] = ((u8 *)&de)[i];
		ok(); break;
	case 0x16: case 0x20:                                                       /* closedir, closefile */
		f = get_fd(H_X);
		if (!f) break;
		f->used = 0;
		if (H_X == search_fd) search_fd = 0xFF;
		ok(); break;
	case 0x18:                                                                  /* openfile (current dirent) */
		n = open_current();
		if (n == 0xFF) break;
		H_A = n; ok(); break;
	case 0x1A: case 0x1C:                                                       /* readfile / writefile: 512 bytes */
		f = file_fd();
		if (!f) break;
		if (fn == 0x1C && !writable()) break;
		got = (fn == 0x1C) ? write_sector(f) : read_sector(f);
		if (got == 0xFFFF) break;
		H_X = (u8)got; H_Y = (u8)(got >> 8);
		if (got == 0) { H_A = 0; H_P &= 0xFE; } else ok();
		break;
	case 0x1E: do_mkfile(); break;
	case 0x22:                                                                  /* closeall */
		for (n = 0; n < NFD; n++) fds[n].used = 0;
		search_fd = 0xFF;
		ok(); break;
	case 0x26: do_rmfile(); break;
	case 0x2E: do_setname(); break;
	case 0x30:                                                                  /* findfirst */
		n = find_first();
		if (n != 0xFF) { H_A = n; ok(); }
		break;
	case 0x32:                                                                  /* findnext */
		if (search_fd == 0xFF) { fail(E_FILE_NOT_FOUND); break; }
		if (find_next(search_fd)) ok(); else { close_search(); de_valid = 0; fail(E_FILE_NOT_FOUND); }
		break;
	case 0x34: if (find_file()) ok(); break;                                    /* findfile */
	case 0x36: do_loadfile(0x00); break;
	case 0x3E: do_loadfile(0x08); break;
	case 0x38: H_A = err; ok(); break;                                          /* geterrorcode */
	case 0x3C: cwd_cluster = root_cluster; ok(); break;                         /* cdrootdir */
	case 0x40: do_attach(0); break;                                             /* d81attach0 */
	case 0x46: do_attach(1); break;                                             /* d81attach1 */
	case 0x42: F_IMG &= 0xC0; ok(); break;                                      /* d81detach */
	case 0x44:                                                                  /* d81write_en */
		if ((F_IMG & 0x03) == 0x03 && !(H_STATE & 0x02)) { F_IMG |= 0x04; ok(); }
		else fail(E_NO_SUCH_DISK);
		break;
	case 0x4A:                                                                  /* attach: X bit 7 detach (bit 1 both), bit 0 drive */
		if (H_X & 0x80) {
			if (H_X & 0x02) F_IMG &= 0xC0;
			else if (H_X & 0x01) F_IMG &= 0xC7;
			else F_IMG &= 0xF8;
			ok();
		}
		else do_attach(H_X & 0x01);
		break;
	default: fail(E_NOT_IMPLEMENTED); break;
	}
}

void hyp_main(void)
{
	u8 trap = H_TRAP;
	/* the sector buffer at $DE00 while we work */
	R(0xD689) |= 0x80;
	SDC_CMD = 0x81;
	if (!inited || (H_STATE & 0xC0)) {
		/* a new card: drop any attached images (after a reset they stay attached) */
		if (!inited || (H_STATE & 0x40)) F_IMG &= 0xC0;
		H_STATE = 0;
		inited = 1;
		fs_init();
	}
	cached = NONE;                  /* the program may have written the buffer */
	fn_a = H_A;
	if (trap == 0) dos(H_A & 0x7E);
	else fail(E_NOT_IMPLEMENTED);
	fat_flush();
	SDC_CMD = 0x82;
}
