--
-- ~/.imapfilter/config.lua
--
-- For more info see http://blog.kylemanna.com/linux/2013/06/09/use-imapfilter-to-filter-spam-part2/
--
require("os")
require("io")
require("posix")

-- Update path for imapfilter relative files
package.path = package.path .. ';' .. os.getenv("HOME") .. '/.imapfilter/?.lua'
require("lua-popen3/pipe")

--
-- Trim whitespace from strings
--
function trim(s)
	return (s:gsub("^%s*(.-)%s*$", "%1"))
end

--
-- Filter the results through spamassassin
--
function filter(results)
	local mailbox
	local uid = {}
	local orig = {}
	local subresult_cnt = 32 -- Number of messages to process in each pass
	local max_procs = 10 -- Number of spamassasin processes to run in parallel

	for subresults, msgs in iter_msgs(results, subresult_cnt) do

		-- Filter it through spamassassin, avoid spamc due to localized
		-- user_perfs and bayes stores owned by this user.  This results
		-- in a minor performance hit (latency) when compared to spamd+spamc.
		local status, allmsg = pipe_multi(msgs, max_procs, 'spamassassin')

		for _, msg in pairs(allmsg) do
			-- TODO Why doesn't the following work?
			--pattern = "^X-Spam-Flag:\\s*YES"
			local pattern = 'X-Spam-Flag:\\s*YES'
			local match = regex_search(pattern, msg)

			local result = 'SPAM'
			if match == true then
				account1.Spam:append_message(msg)
			else
				result = 'normal'
				account1.INBOX:append_message(msg)
			end

			--pattern = 'Subject:\\s*(.*)\n'
			--match2, cap = regex_search(pattern, msg)
			if subject == nil then
				subject = '(unknown)'
			end
			local out = '>> Msg "' .. subject ..  '" is ' .. result .. '\n'
			io.write(out)
		end

		-- Make old messages as seen and keep them
		-- Later we might delete them after we trust this filter
		subresults:mark_seen()
	end
end

--
-- Split up a large imapfilter result into chunk sizes
-- by iterating over it. Provides a way to elegantly
-- handle large results without blowing up memory
--
function iter_msgs(results, chunk)

	local i = 1
	local last = 0
	local max = #results

	return function()
		local subresults = {}
		local msgs = {}
		while i <= (last + chunk) and i <= max do
			local mailbox, uid = table.unpack(results[i])
			local mbox = mailbox[uid]
			local msg = mbox:fetch_message()
			table.insert(msgs, msg)
			table.insert(subresults, results[i])
			i = i + 1
		end
		last = i
		if next(subresults) then
			return Set(subresults), msgs
		end
	end
end

--
-- Feed spam messages to sa-learn to teach the bayesian classifier
--
function sa_learn(learn_type, results, dest)
	local learn_arg = '--' .. learn_type
	local subresult_cnt = 32 -- Number of messages to process in each pass
	local max_procs = 1 -- Number of sa-learn processes to run in parallel

	for subresults, msgs in iter_msgs(results, subresult_cnt) do
		local status = pipe_multi(msgs, max_procs, 'sa-learn', learn_arg)

		--[[
		for s in ipairs(status) do
			io.write('>> sa-learn returned '..s..'\n')
		end
		--]]
		subresults:move_messages(dest)
	end
end

--
-- Run in an infinite loop
--
function forever()

	--max_filter_size = 1024 * 1024 -- 1024 KB
	max_filter_size = 512000 -- 1024 KB

	account1:create_mailbox('Spam')
	account1:create_mailbox('Spam/False Positives')
	account1:create_mailbox('Spam/False Negatives')
	account1:create_mailbox('Spam/False Positives/Processed')
	account1:create_mailbox('Spam/False Negatives/Processed')

	local unfiltered = account1['Unfiltered']
	local spam = account1['Spam']
	local false_pos = account1['Spam/False Positives']
	local false_pos_done = account1['Spam/False Positives/Processed']
	local false_neg = account1['Spam/False Negatives']
	local false_neg_done = account1['Spam/False Negatives/Processed']

	while true do

		-- Loop over the results in the event a new message shows up
		-- while we are proccessing earlier ones.
		local unseen = unfiltered:is_unseen()

		-- Just move the large messages
		local large = unfiltered:is_larger(max_filter_size)
		local results = unseen * large
		results:copy_messages(account1.INBOX)
		results:mark_seen()

		-- Filter the remaining messages
		local results = unseen - large
		filter(results)


		--
		-- House keeping... Other work to do?
		--

		-- Check for messages older then x days in the original inbox
		-- and delete them
		results = unfiltered:is_older(14):delete_messages()
		results = spam:is_older(60):delete_messages()

		-- Teach spamassassin about the good email that was marked as spam
		results = false_pos:is_smaller(max_filter_size)
		sa_learn('ham', results, false_pos_done)

		-- Teach spamassassin about the messages it missed
		results = false_neg:is_smaller(max_filter_size)
		sa_learn('spam', results, false_neg_done)

		-- Block until something happens, assuming server supports IMAP IDLE
		-- Note: there is still a window between checking unseen messages
		-- and entering idle where we could miss a new arrival.  In that
		-- case it will have to wait until another email arrives.
		if #unfiltered:is_unseen() == 0 then
			local update = unfiltered:enter_idle()

			-- Sleep 60 seconds if IDLE isn't supported
			if update == false then
				posix.sleep(60)
			end
		end
	end
end


---------------
--  Options  --
---------------

options.timeout = 120
options.keepalive = 5
--options.subscribe = true


----------------
--  Accounts  --
----------------
-- include ~/.imapfilter/accounts.lua (assuming package.path is set correctly)
require("accounts")


forever()
-- Daemon mode fails to properly recover when the remote server trips
-- and the connection closes, so it needs to be run in a wrapper script.
--become_daemon(600, forever)
