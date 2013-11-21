#
# (C) 2011 coolo@suse.de, Novell Inc, openSUSE.org
# Distribute under GPLv2 or GPLv3
#
# Copy this script to ~/.osc-plugins/ or /var/lib/osc-plugins .
# Then try to run 'osc checker --help' to see the usage.


import socket
import os
import traceback
import subprocess

def _checker_parse_name(self, apiurl, project, package, revision=None, brief=False, verbose=False):

    if revision:
        url = makeurl(apiurl, ['source', project, package], { 'view':'info', 'parse':1, 'rev':revision})
    else:
        url = makeurl(apiurl, ['source', project, package], { 'view':'info', 'parse':1  } )

    try:
        f = http_GET(url)
    except urllib2.HTTPError, err:
        return None
    xml = ET.parse(f)

    name = xml.find('name')
    if name is None or not name.text:
       return None

    return name.text

def _checker_change_review_state(self, opts, id, newstate, by_group='', by_user='', message='', supersed=None):
    """ taken from osc/osc/core.py, improved:
        - verbose option added,
        - empty by_user=& removed.
        - numeric id can be int().
    """
    query = {'cmd': 'changereviewstate', 'newstate': newstate }
    if by_group:  query['by_group'] = by_group
    if by_user:   query['by_user'] = by_user
    if supersed: query['superseded_by'] = supersed
#    if message: query['comment'] = message
    u = makeurl(opts.apiurl, ['request', str(id)], query=query)
    f = http_POST(u, data=message)
    root = ET.parse(f).getroot()
    return root.attrib['code']

def _checker_prepare_dir(self, dir):
    olddir=os.getcwd()
    os.chdir(dir)
    shutil.rmtree(".osc")
    os.chdir(olddir)

def _checker_accept_request(self, opts, id, msg):
    code = 100
    query = { 'cmd': 'addreview', 'by_group':'opensuse-review-team' }
    url = makeurl(opts.apiurl, ['request', str(id)], query)
    if opts.verbose: print(url)
    try:
        r = http_POST(url, data="Please review sources")
    except urllib2.HTTPError, err:
        return 1
    code = ET.parse(r).getroot().attrib['code']
    if code == 100 or code == 'ok':
         self._checker_change_review_state(opts, id, 'accepted', by_group='factory-auto', message=msg)
         print("accepted " + msg)
    # now gets risky
    query = { 'cmd': 'addreview', 'by_user':'factory-repo-checker' }
    url = makeurl(opts.apiurl, ['request', str(id)], query)
    try:
        r = http_POST(url, data="Please review build success")
    except urllib2.HTTPError, err:
        pass # there is no good mean to undo
    return 0

def _checker_one_request(self, rq, cmd, opts):
    if (opts.verbose):
        ET.dump(rq)
        print(opts)
    id = int(rq.get('id'))
    act_id = 0
    approved_actions = 0
    actions = rq.findall('action')
    if len(actions) > 1:
       msg = "2 actions in one SR is not supported - https://github.com/coolo/factory-auto/fork_select"
       self._checker_change_review_state(opts, id, 'declined', by_group='factory-auto', message=msg)
       print("declined " + msg)
       return
 
    for act in actions:
        act_id += 1
        _type = act.get('type');
        if (_type == "submit"):
            pkg = act.find('source').get('package')
            prj = act.find('source').get('project')
            rev = act.find('source').get('rev')
            tprj = act.find('target').get('project')
            tpkg = act.find('target').get('package')

            src = { 'package': pkg, 'project': prj, 'rev':rev, 'error': None }
            e = []
            if not pkg:
                e.append('no source/package in request %d, action %d' % (id, act_id))
            if not prj:
                e.append('no source/project in request %d, action %d' % (id, act_id))
            if len(e): src.error = '; '.join(e)

            e = []
            if not tpkg:
                e.append('no target/package in request %d, action %d; ' % (id, act_id))
            if not prj:
                e.append('no target/project in request %d, action %d; ' % (id, act_id))
            # it is no error, if the target package dies not exist

            subm_id = "SUBMIT(%d):" % id
            print ("\n%s %s/%s -> %s/%s" % (subm_id,
                prj,  pkg,
                tprj, tpkg))
            dpkg = self._checker_check_devel_package(opts, tprj, tpkg)
            #self._devel_projects['X11:QtDesktop/'] = 'rabbitmq'
	    #self._devel_projects['devel:languages:erlang/'] = 'ruby19'
            #self._devel_projects['devel:languages:nodejs/'] = 'nodejs'
	    self._devel_projects['mozilla:addons/'] = 'x2go'
	    self._devel_projects['X11:MATE:Factory/'] = 'mate'
	    self._devel_projects['network:wicked:factory/'] = 'wicked'
            if dpkg:
                [dprj, dpkg] = dpkg.split('/')
            else:
                dprj = None
            if dprj and (dprj != prj or dpkg != pkg) and (not os.environ.has_key("IGNORE_DEVEL_PROJECTS")):
                msg = "'%s/%s' is the devel package, submission is from '%s'" % (dprj, dpkg, prj)
                self._checker_change_review_state(opts, id, 'declined', by_group='factory-auto', message=msg)
                print("declined " + msg)
                continue
            if not dprj and not self._devel_projects.has_key(prj + "/"):
                msg = "'%s' is not a valid devel project of %s - please pick one of the existent" % (prj, tprj)
                self._checker_change_review_state(opts, id, 'declined', by_group='factory-auto', message=msg)
                print("declined " + msg)
                continue

            dir = os.path.expanduser("~/co/%s" % str(id))
            if os.path.exists(dir):
                print("%s already exists" % dir)
                continue
            os.makedirs(dir)
            os.chdir(dir)
            try:
                checkout_package(opts.apiurl, tprj, tpkg, pathname=dir,
                                 server_service_files=True, expand_link=True)
                self._checker_prepare_dir(tpkg)
                os.rename(tpkg, "_old")
            except urllib2.HTTPError:
		print("failed to checkout %s/%s" % (tprj, tpkg))
                pass
            checkout_package(opts.apiurl, prj, pkg, revision=rev,
                             pathname=dir, server_service_files=True, expand_link=True)
            os.rename(pkg, tpkg)
            self._checker_prepare_dir(tpkg)

  	    r=self._checker_parse_name(opts.apiurl, prj, pkg, revision=rev)
	    if r != tpkg:
		msg = "A pkg submitted as %s has to build as 'Name: %s' - found Name '%s'" % (tpkg, tpkg, r)
                self._checker_change_review_state(opts, id, 'declined', by_group='factory-auto', message=msg)
		continue

            sourcechecker = os.path.dirname(os.path.realpath(os.path.expanduser('~/.osc-plugins/osc-check_source.py')))
            sourcechecker = os.path.join(sourcechecker, 'source-checker.pl')
            civs = "LC_ALL=C perl %s _old %s 2>&1" % (sourcechecker, tpkg)
            p = subprocess.Popen(civs, shell=True, stdout=subprocess.PIPE, close_fds=True)
            ret = os.waitpid(p.pid, 0)[1]
            checked = p.stdout.readlines()
            output = '  '.join(checked).translate(None, '\033')
            os.chdir("/tmp")
            
            if ret != 0:
                msg = "Output of check script:\n" + output
                self._checker_change_review_state(opts, id, 'declined', by_group='factory-auto', message=msg)
                print("declined " + msg)
		shutil.rmtree(dir)
                continue

	    shutil.rmtree(dir)
            msg="Check script succeeded"
            if len(checked):
                msg = msg + "\n\nOutput of check script (non-fatal):\n" + output
                
            if self._checker_accept_request(opts, id, msg):
               continue

        else:
            self._checker_change_review_state(opts, id, 'accepted',
                                              by_group='factory-auto',
                                              message="Unchecked request type %s" % _type)

def _checker_check_devel_package(self, opts, project, package):
    if not self._devel_projects.has_key(project):
        url = makeurl(opts.apiurl, ['search','package'], "match=[@project='%s']" % project)
        f = http_GET(url)
        root = ET.parse(f).getroot()
        for p in root.findall('package'):
            name = p.attrib['name']
            d = p.find('devel')
            if d != None:
                dprj = d.attrib['project']
                self._devel_projects["%s/%s" % (project, name)] = "%s/%s" % (dprj, d.attrib['package'])
                # for new packages to check
                self._devel_projects[dprj + "/"] = 1
            elif not name.startswith("_product"):
                print("NO DEVEL IN", name)
            # mark we tried
            self._devel_projects[project] = 1
    try:
        return self._devel_projects["%s/%s" % (project, package)]
    except KeyError:
        return None

def do_check_source(self, subcmd, opts, *args):
    """${cmd_name}: checker review of submit requests.

    Usage:
      osc check_source [OPT] [list] [FILTER|PACKAGE_SRC]
           Shows pending review requests and their current state.

    ${cmd_option_list}
    """

    if len(args) == 0:
        raise oscerr.WrongArgs("Please give a subcommand to 'osc checker' or try 'osc help checker'")

    self._devel_projects = {}
    opts.verbose = False

    from pprint import pprint

    opts.apiurl = self.get_api_url()

    tmphome = None

    if args[0] == 'skip':
        for id in args[1:]:
           self._checker_accept_request(opts, id, "skip review")
        return
    ids = {}
    for a in args:
        if (re.match('\d+', a)):
            ids[a] = 1

    if (not len(ids)):
        # xpath query, using the -m, -r, -s options
        where = "@by_group='factory-auto'+and+@state='new'"

        url = makeurl(opts.apiurl, ['search','request'], "match=state/@name='review'+and+review["+where+"]")
        f = http_GET(url)
        root = ET.parse(f).getroot()
        for rq in root.findall('request'):
            tprj = rq.find('action/target').get('project')
            self._checker_one_request(rq, args[0], opts)
    else:
        # we have a list, use them.
        for id in ids.keys():
            url = makeurl(opts.apiurl, ['request', id])
            f = http_GET(url)
            xml = ET.parse(f)
            root = xml.getroot()
            self._checker_one_request(root, args[0], opts)

#Local Variables:
#mode: python
#py-indent-offset: 4
#tab-width: 8
#End:
